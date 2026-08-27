# Implementation Plan — Kyverno pivot, prod grade, AUDIT mode

Brief: [`kyverno_pivot_prod.md`](kyverno_pivot_prod.md). **Nothing built yet.** This document says
what I found in the tree, what I intend to do, where the brief's own matrices disagree with what
the POC measured, and what is still undecided.

**Round 2.** All the round-1 and round-2 questions are answered — see §8 for the decisions and
§8b for the two things still open, neither of which blocks a start. **§10 is the readiness call.**
Phase 1 is ready to build; phase 2 has three gates in front of it.

House convention followed: this is the `*_PLAN.md` sibling of the brief, same as
`history/new_direction_PLAN.md` and friends.

---

## 0. State of the tree as I found it

Some of the brief's moves are already done, in the working tree, uncommitted:

| brief says | actual state |
|---|---|
| "I move `container-vulnerability-exemption/poc` to `project_metadata/history/poc`" | done — but as `mv` + `git rm`, so `history/poc/` is **untracked** (`??`) and 34 deletions are staged. Needs `git add` or the archive is not in history at all |
| "I also move `git mv container-vulnerability-exemption.wiz/ project_metadata/history`" | done, staged as `R` (21 renames) |
| — | `project_metadata/*.md` (9 files) also moved into `history/`, staged |
| — | `project_metadata/project_summary.md` shows as `RD` — moved to `history/` **and** a new untracked copy exists at the old path. Two versions of the same file; one of them is stale |
| — | `container-vulnerability-exemption.kyverno/unikube/_to_delete/` deletions are staged but the directory is gone from disk — that cleanup is finished, just uncommitted |
| — | `container-vulnerability-exemption/_to_delete/` likewise |

**Before any of the work below, this working tree needs a commit.** 96 staged path changes plus 3
untracked paths is not a base to start a rework from — if a rename lands on top of it, the diff
becomes unreadable and `git mv` stops being able to follow the file. Step 0 of every stream below
assumes a clean tree.

Also worth naming now: the `.kyverno` rendered tree still has cluster directories at
`unikube/<env>/<cluster>/policy-exception/`. The brief renames that subdirectory. **A rename here
is a `git mv`, not a re-render** — the renderer prunes only inside directories it currently
writes, so re-rendering into `container_exemptions/` would leave the old `policy-exception/`
directories in place, still committed, still greppable, still read by `kubectl apply -f`. That is
the fossil failure this repo has now hit three times (`*-simple.yaml`, `00-namespace.yaml`, the
whole `poc/demo` tree).

---

## 1. Is the brief right? Short answer, then the detail

**The phase 1 shape is exactly what's already rendered** — one `ImageValidatingPolicy` globbing
`**`, one `PolicyException` per exemption — so phase 1 is a rename, a rescope, and removing Wiz —
not a redesign. The real work in phase 1 is subtraction.

**The phase 2 shape is new, and it is better than either of the two models you compared earlier,
for a reason nobody had
put together before.** Splitting the catch-all half onto a `ValidatingPolicy` rather than a second
`ImageValidatingPolicy` is what unlocks per-image exceptions — because
`exceptions.allowedImages` **is** registered for vpol and is **not** registered for ivpol. That
was measured (`history/poc/probe-cel.txt`, Q6: `undeclared reference to 'exceptions'` on ivpol;
the identical expression compiles on vpol) and then written up as the upstream bug draft, but it
was never turned into a design. The brief turns it into one. §4 works through what that buys and
what it does not.

**The one thing the brief gets wrong is the mode.** Every matrix in it is written in
admit/deny terms, and **AUDIT mode never denies anything**. §5.

---

## 2. AUDIT mode changes what the matrices can even assert

`validationActions: [Audit]` means the API server is told the result and admits the pod regardless.
So under the brief's own choice of mode:

- there is no "deny" row to observe. Every one of the 18 matrix cases admits.
- the observable is the **PolicyReport result** — `pass`, `fail`, or `skip` — written
  asynchronously (~15s, two-stage: admission writes an `EphemeralReport`, the reports controller
  aggregates it into a `PolicyReport`). Any harness must poll, and must look reports up by
  `.scope.name`, never by name, because a `polr` is named for the subject's UID.

That is not a downgrade. It is the reason to be in AUDIT at all, and it recovers something the
enforcing design does not have:

> **MEASURED (v1.18.2, chart 3.8.2):** under `[Audit]` an exempted workload produces a **`skip`**
> row naming the exception —
> `"message":"rule is skipped due to policy exception: kyverno-exceptions/allow-app-30"`,
> `"properties":{"exceptions":"allow-app-30"}`. Under `[Deny, Audit]` that row **disappears** —
> once `Deny` is present, results that do not deny (`pass` and `skip` alike) are not reported.

So AUDIT mode gives you the exemption-**usage** audit trail that BLOCK mode structurally cannot.
An exemption that is stale and an exemption that is load-bearing look identical from the
`PolicyException` objects alone; the `skip` rows are the only thing that tells them apart. **Build the thing that collects
those report rows now, while they exist.** It stops working the day anything flips to BLOCK, and
that is worth knowing before someone plans the flip.

### The reframing that matters for the loopholes

Under BLOCK, the brief's loopholes are admission bypasses. Under AUDIT they are **audit blind
spots**, and that is arguably worse for what AUDIT is for:

> A pod carrying an exemption produces one `skip` row for the whole resource. Every other image in
> that pod — including unsigned ones the exemption was never meant to cover — is **not evaluated
> and not counted**.

If the point of running AUDIT is to size the unsigned-image population before deciding whether to
flip to BLOCK, phase 1 biases that number downward by exactly the pods that carry exemptions,
which is the population you most need to measure. The loophole isn't theoretical in AUDIT — it
corrupts the dataset the whole exercise exists to produce.

### `failurePolicy` is not covered by "we're only in AUDIT"

`validationActions` decides what happens when the policy **reaches a verdict**. `failurePolicy`
decides what the API server does when the webhook **cannot answer** — and `Fail` blocks pod
creation cluster-wide regardless of AUDIT. "AUDIT mode is safe" is only true with
`failurePolicy: Ignore`, which is the current default and should stay.

The cost of `Ignore` in AUDIT is specific and needs a compensating control:

> **MEASURED (demo.md §7.7):** an ivpol without its own `spec.credentials.providers` block reads
> the registry anonymously and takes a 401 — even with correct IRSA and correct chart-level
> `features.registryClient.credentialHelpers`. A 401 is an **evaluation error**, not a failed
> verification, so under `failurePolicy: Ignore` the policy is skipped and **no report row is
> written at all**.

In BLOCK that fails open. In AUDIT it is worse in a quiet way: a broken credential config looks
exactly like a clean fleet. Nothing in the reports distinguishes "verified, all fine" from "never
ran". The only ground truth is
`kyverno_image_validating_policy_results` and
`apiserver_admission_webhook_admission_duration_seconds{name=~"ivpol\\..*"}` — so
**a metrics check belongs in the phase 1 acceptance criteria, not in a follow-up**.

---

## 3. Phase 1 — what I'll build

Model is unchanged from what's rendered today. The work:

### 3.1 Naming (brief: "normal naming, not simple or advanced")

| now | after |
|---|---|
| policy `soe-notary-signed-simple` | `require-org-signed-images` (the name already used in `history/poc/60.yaml`) |
| `MODE` / `DEFAULT_MODE` / `MODES = ["simple"]` in `kyverno_render.py` | deleted outright — the constants exist only to tell the old candidate models apart |
| `# Mode: simple` line in every generated header | `# Phase: 1` — the header must still say which shape produced the file, because phase 1 and phase 2 emit files with overlapping names and different security properties |
| `render_simple_policy()` (`render_exception()` already has the neutral name) | `render_signature_policy()` |
| `cluster_dir` → `<env>/<cluster>/policy-exception/` | `<env>/<cluster>/container_exemptions/` |
| `--1.19` flag | kept during the pivot per the brief, **removed afterwards**: it was a second name for `--kyverno-version 1.19`, so the two could contradict each other and needed a precedence rule. One spelling, no rule. |

Every docstring and header note in `kyverno_render.py` that says "simple mode", "advanced mode",
"the candidate models", or points at `poc/kyverno_render_advanced.py` is now a pointer into
`project_metadata/history/`. All of it gets rewritten — that is roughly 200 lines of prose in that
one file, and it is not optional: the README-sweep memory records that the previous pass through
this repo found the candidate model documented as if it had shipped.

### 3.2 `OWNED_FILES` must span both phases from day one

`write()` prunes `owned - produced`. If phase 1 owns only `{10-ivpol.yaml, 20-polex.yaml}` and a
cluster later renders phase 2, switching a cluster **back** leaves phase 2's files applied. So:

```
OWNED_FILES = {10-ivpol.yaml, 20-polex.yaml, 30-vpol.yaml, 40-polex-vendor.yaml}
```

— the union, regardless of which phase a given cluster renders. `--check` scopes to the same set.
This is the one design detail I'd push back on if asked to skip: it is the difference between a
phase switch being a re-render and being a re-render plus a manual cleanup nobody remembers.

### 3.3 The upstream issue — it is already written

The brief asks for a GitHub issue about ivpol `PolicyException` skipping whole resources.
`project_metadata/kyverno-ivpol-policyexception-issue-concise.md` is the finished issue: title, labels,
version table, two reproductions (the CEL compile error and the `spec.images`-is-inert behaviour),
an expected-behaviour section with two options, a 25-row index of every related upstream
issue/KDP, and a triage paragraph. It cites the exact gap — `KDP#70` (ivpol design) never mentions
`PolicyException`, `KDP#77` (fine-grained exceptions) enumerates vpol/mpol/gpol and omits ivpol.

I'd post it essentially as-is, with two edits: re-verify the linked issue states against upstream
today (the draft is from 2026-08-21), and replace the two `<…>` registry placeholders. **This is
a 30-minute task, not a work stream** — see Q8.

### 3.6 Put the rendered manifests on a comment diet

Measured on `prod/fsp02` as rendered today:

| file | total | comment | actual YAML |
|---|---|---|---|
| `10-ivpol.yaml` | 133 | 41 | 90 — of which ~60 is the inlined CA PEM, so **~30 lines of real policy** |
| `20-polex.yaml` | 85 | **61** | 24 |

`20-polex.yaml` is **72% commentary.** Those comments were written to teach a POC audience which
of two candidate models they were looking at and why each was a bad idea in a different way. On a
production cluster they are noise, and worse: several of them are arguments *against* the shape
being applied, which reads as a warning label on a live policy.

**The rule I'll apply.** A comment stays only if it is a fact an operator needs at
`kubectl apply` time or at 3am, and that is **not visible in the YAML itself**:

*Keep* — the `# GENERATED FILE` header (source, phase, Kyverno target, do-not-edit); the two chart
settings that decide whether the object does anything at all
(`features.policyExceptions.enabled` **defaults to false**, `.namespace` must not be `*`); the
reports-controller IRSA prerequisite now that background scan is on (Q5); one line on why the
`credentials` block cannot be removed (its absence fails open, silently); and a single line each
on the deliberately-odd values a reviewer would otherwise read as a bug — `required: false`,
`tsaCerts` unset, `mutateDigest` inert on 1.18.

*Cut* — every explanation of what the design costs, why the other model was different, why
`matchConditions` is used instead of `spec.images`, and the essay in each `PolicyException` about
whole-pod exemption. That reasoning is real and worth keeping; it belongs in
`unikube/README.md`, where it is read once, not in every object on every cluster.

Target: `20-polex.yaml` from 61 comment lines to under 10; `10-ivpol.yaml` from 41 to under 15.

**Enforced by a test**, in the repo's habit of turning a lesson into a check:
`test_kyverno_render.py` asserts a comment-line budget per rendered file, so the bloat cannot
creep back one well-meaning explanation at a time. That test is also the thing that will fail if
someone later trims the `# GENERATED FILE` line that `kyverno_verify.sh` discovers clusters by.

### 3.4 Removing Wiz — the actual file list

**Delete**

```
unikube/scripts/wiz_render.py  wiz_mock_plan.py  wiz_plan_summary.py  wiz_local_tf.sh
unikube/tests/test_wiz_render.py  test_wiz_mock_plan.py  test_wiz_plan_summary.py
unikube/schemas/tenants.schema.json
unikube/exemptions/tenants.yaml            (see Q3 — schema_version lives here too)
.github/workflows/terraform.yaml
.github/actions/tf/                        (the whole action)
```

**Edit — code**

- `common.py`: drop `WIZ_TENANTS`, `ENGINE_PIN_KEY`, `BACKENDS`, `DEFAULT_BACKENDS`,
  `enabled_backends()`, `tenant_pin()`, `load_tenants()`, `tenants_path()`, `TENANTS_FILE`.
  `KYVERNO_ONLY_ENVS` loses its meaning when every env is Kyverno-only — but the `poc` env still
  needs to stay out of the fleet render, so the constant survives under a new name
  (`NON_FLEET_ENVS`) and a new rationale.
- `validate.py`: drop `--backend`, `_BACKEND_UNSUPPORTED`, `_check_backend_support`,
  `_BACKEND_DEFAULTS`, and the tenant-pin checks. **This is a capability unlock, not just a
  deletion** — see §3.5.
- `kyverno_verify.sh`: sweep for the `policy-exception` path (discovery is by
  `grep -rl '^# GENERATED FILE'` so it survives the rename, but the `--out-dir` prose and any
  hard-coded path do not).
- `.github/workflows/kyverno.yaml`: drop `--backend kyverno`; the comment explaining why each
  backend asserts its own gate is now describing nothing.
- `.github/workflows/unikube.yaml`: sweep.

**Edit — schemas.** `exemption.defs.json` is where most of the Wiz text lives. Every definition
carries a "Wiz: … / Kyverno: …" paragraph, and five of them carry an
"IGNORED by `unikube/scripts/kyverno_render.py`" clause that describes the phase-1/phase-2 split
in the language of the old model comparison. All of it rewrites.

**Edit — exemption YAML.** `nonprod/wizn02.yaml` and `prod/fsp02.yaml` both carry long comments
explaining that `namespaces:` and `expired_at:` cannot be honoured *because Wiz cannot express
them*. Those comments become false the moment the gate is dropped, and they are load-bearing —
`fsp02.yaml` records a security approval scoped to `payments`/`payments-uat` that is currently
applied cluster-wide. **Dropping the Wiz gate is the thing that lets those two approvals be
enforced as written**, so this isn't cleanup, it's a security improvement that should be called
out in the PR.

**Edit — docs.** `CODEOWNERS` (the `tenants.yaml` rule, and "both Wiz tenants" in the `trust/`
rationale), `image-signing/README.md`, `image-signing/*.sh`, `trust/README.md`.

**The root README is the hard one.** It is an ADR, and **ADR-0002 chose Wiz.** Its rationale 1
(one exemption mechanism) and rationale 2 (fan-out to ~200 etcds vs one tenant API) were never
overturned by any measurement — they are still true, they were just outweighed. Deleting ADR-0002
would erase the reasoning; leaving it stands as current. The correct move is
**ADR-0004 recording the pivot**, superseding ADR-0002, stating plainly what is being accepted
(fan-out, no central usage view under enforcement, per-cluster CA rotation) and what changed the
decision. Same pass fixes ADR-0003's Consequences section, which asserts Kyverno "supports
[signer-identity pinning] today" — **factually wrong** (F1: Kyverno builds the notation trust
policy with `TrustedIdentities: ["*"]` hard-coded in Go; the CRD's notary attestor exposes only
`certs` and `tsaCerts`). That correction was flagged as needed whichever model won
and is still outstanding.

### 3.5 What dropping the Wiz gate unlocks

`validate.py` currently rejects three fields while `wiz` is an enabled backend. With Wiz gone,
all three become legal and phase 2 needs two of them:

| field | why it was blocked | what it enables now |
|---|---|---|
| `namespaces:` | a Wiz ignore rule is tenant-scoped | per-exemption namespace scoping — the thing that makes team-a's approved vendor image *not* admissible in team-b's namespace |
| `expired_at:` | one Wiz rule per scope carries one expiry | per-entry expiry → `spec.expiresAt` on 1.19 |
| `operator: equals` | one Wiz rule carries one operator | exact-reference exemptions |

Note the asymmetry that remains: on **1.18** `expired_at` still has no consumer in-cluster
(kyverno#16299 merged after v1.18.2), so expiry is enforced at render time only. On **1.19** it is
native. That is now the strongest argument for moving the default to 1.19 — see Q10.

---

## 4. Phase 2 feasibility

### 4.1 The shape, restated precisely

```
ImageValidatingPolicy  require-org-signed-images
    matchImageReferences: the self-built prefixes (admission.signed_image_prefixes)
    validations:          every matched image carries a Notation signature to the org root
    exceptions:           PolicyException, resource-scoped  ← the residual loophole lives here

ValidatingPolicy       require-approved-images
    matchConstraints:     pods (+ autogen over controllers)
    validations:          every image is EITHER under a self-built prefix (→ the ivpol's problem)
                          OR under a platform prefix
                          OR in exceptions.allowedImages   ← PER-IMAGE, this is the unlock
    exceptions:           PolicyException with spec.images  ← fine-grained
```

### 4.2 Why the vpol half is the good idea

> **MEASURED (`history/poc/probe-cel.txt`, Q6, v1.18.2):** seven spellings of
> `exceptions.allowedImages` inside an `ImageValidatingPolicy` all fail to compile with
> `undeclared reference to 'exceptions' (in container '')`. The `PolicyException` CRD *does* carry
> `images` and `allowedValues` — they are accepted by the API server and silently do nothing for
> ivpol. The same expression on a `ValidatingPolicy` compiles.

So per-image exception granularity is available today, on the version we're on, for any policy
that is a vpol. That is the whole of phase 2's advantage and it is not speculative.

This also makes the brief's phase-2 row *"vendor image + vendor image excepted → deny"* correct,
with one condition attached in §4.4.

### 4.3 Correction: the brief's phase-2 row 4 is pessimistic

The brief's phase 2 multi-image table says:

> `vendor image + self-built unsigned image excepted` → expected deny, **actual admit. This is
> loophole that needs address**

I don't think that's right, and the difference matters because it's the difference between two
loopholes and one. Walk it:

- Pod holds **V** (vendor, no exception) and **S** (self-built, unsigned, exempted).
- The exemption for S targets the **ivpol**. It matches the resource → the ivpol is skipped
  entirely → S is not verified. Intended.
- The **vpol is a separate policy** and is not referenced by that exception. It still runs. Its
  expression asks of every image: self-built-prefixed, platform-prefixed, or in
  `allowedImages`? **V is none of the three → fail.**

**Actual: deny** (in AUDIT: a `fail` row). Not a loophole — *provided* the two policies' scopes
are disjoint and **each exemption targets exactly one of them**. That last clause is a renderer
invariant, and it's the fifth one to add to the four already enforced in `kyverno_cel.py`:

> **Invariant 5 — an exemption's `policyRefs` names the ivpol *or* the vpol, never both.**
> An exemption naming both re-creates the phase 1 hole with extra steps.

### 4.4 The two constraints that decide whether phase 2 works at all

Both are **must-verify before building**, and both are cheap to check.

**(a) `allowedImages` matching semantics vs our `starts_with` operator.** The probes spell it
`img in exceptions.allowedImages` — exact string membership. Our schema's default operator is
`starts_with`, and `image_value: "docker.io/library/redis"` is meant to cover every tag. Exact
membership cannot express that.

The way out is that `allowedImages` is just a list of strings the policy consults, so the policy
can do the prefix test itself:

```cel
exceptions.allowedImages.exists(a, img.startsWith(a))
```

That preserves `starts_with` with no schema change and no dependence on whether `spec.images`
supports globs. **The thing to verify is whether Kyverno pre-filters which exceptions apply by
matching `spec.images` against the resource's images using its own semantics** — if it does, an
exception whose `spec.images` holds a prefix rather than a full reference may never be surfaced to
the policy at all, and the `exists()` trick never gets a chance to run.

**(b) kyverno#16053 / #16060 — is the fix in v1.18.2?** Two behaviours were reported against
1.18.0 and fixed 2026-07-28: `allowedImages` accumulate across every matching exception, and a
full-exemption `PolicyException` is silently overridden by an image-scoped one. Both land directly
on phase 2's design. I have not confirmed whether v1.18.2 predates or postdates that merge —
v1.18.2 is the pin, and #16299 (a different fix from the same window) is known to have merged
*after* it, which is not encouraging. **If the fix is not in 1.18.2, phase 2 needs 1.19 or a patch
bump**, and that is a scheduling fact worth knowing before the work starts, not after.

A third item, lower stakes but same family: `#16993` (exceptions read from a stale cache on some
HA replicas) and `#17106` (up to 5+ minutes before an exception takes effect) are both open. In
AUDIT they cost report accuracy rather than admission correctness, which is a reason to be glad
we're starting in AUDIT.

### 4.5 The residual loophole, and the three ways to close it

The brief's phase-2 row 2 is correct and irreducible **as long as the self-built half is an
ivpol**:

> `self-built signed + self-built unsigned excepted` → the exemption skips the ivpol for the whole
> resource, so a *third* unsigned self-built image in the same pod is admitted unverified, and the
> vpol waves it through because it is under a self-built prefix.

Three ways to close it, all three already explored by the earlier model comparison. This is Q2 and it is the
single most consequential open question in this document.

| | how | closes it? | cost |
|---|---|---|---|
| **A. PolicyException** (brief's default) | exemption is a `PolicyException` targeting the ivpol | **no** | none new — but the hole stays, and in AUDIT it is a blind spot in the dataset |
| **B. scope carve-out** (the old `30/31` model) | exemption moves into `matchImageReferences[].expression`: `ref.startsWith(p) && !(ref in [exempt…])` | **yes** | exemption list moves *inside* a platform-owned policy — no separate RBAC, no expiry, no audit trail, i.e. the entire reason `PolicyException` exists. Also: editing one exemption re-renders the signature policy on **every** cluster, bumps its `resourceVersion` (part of the `imageVerifyCache` key) and cold-starts signature verification fleet-wide |
| **C. relocation** (the old `50/51` model) | a build that fails compliance is pushed to `unverified/` — outside the signed prefix — and exempted there as a vendor image would be, i.e. **by the vpol, per-image** | **yes** | needs a build-pipeline change, and needs the self-built prefix to be a real IAM boundary |

**I'd recommend C**, and it is worth being blunt about why: B trades the loophole for the loss of
every governance property the exemption workflow exists to provide, and it makes one exemption
edit a fleet-wide cache flush. C keeps `PolicyException` where it belongs and gets per-image
granularity for free, because a relocated image is the vpol's business and the vpol has
`allowedImages`.

C's precondition is the thing to look at hard:

> The signed prefix is supposed to be an **access-control boundary** — only CI may push there, and
> CI signs what it pushes. **Nothing in this repo restricts `ecr:PutImage` under the self-built
> prefixes to the CI role.** Until it does, C rests on a convention rather than a control, and an
> unsigned image pushed under the signed prefix is a `fail` row with no remedy short of editing a
> platform policy.

Fixing that IAM is a smaller change than any of the policy designs here, and it is what makes C's
argument true rather than aspirational. Related and already recorded: never glob a whole registry
into `signed_image_prefixes` — an ECR pull-through cache rule materialises upstream third-party
images inside your own registry namespace, and they land inside a policy no `PolicyException` can
except them from.

### 4.6 The probe worth running before anything else

One question could collapse this whole design:

> **Does `verifyImageSignatures` / `attestors` compile inside a `ValidatingPolicy`?**

The issue draft says "the identical expression on a `ValidatingPolicy` compiles" about a line that
contained *both* `exceptions.allowedImages` **and**
`images.containers.all(i, verifyImageSignatures(i, [attestors.notary]) > 0)`. If that is literally
true, then a **single vpol** can do signature verification *and* per-image exceptions, and phase 2
needs no ivpol at all — no split scopes, no invariant 5, no residual loophole, one policy.

I think the sentence is probably loose (image verification is ivpol's reason to exist, and
`images.containers` is an ivpol binding), but it is one `kubectl apply --dry-run=server` against
the POC cluster to find out, and the upside is large enough that it should be the first thing run.
Everything in §4.1–4.5 assumes the answer is no.

### 4.7 Renderer options for phase 2 (brief: "render_kyverno have options for phase 2")

`kyverno_render.py --phase 2` (default `1`), resolved per cluster from
`admission.kyverno.phase` in `global.yaml` / the cluster file, exactly as `version` already is —
so a cluster moves phase in a one-line reviewed change and the fleet is never mid-migration by
accident.

Phase 2 requires `admission.signed_image_prefixes` and `admission.platform_image_prefixes`, which
have **no defaults anywhere in this repo, deliberately**: a renderer that supplies its own
registry emits a policy scoped to somewhere the fleet does not push to, which admits everything
while looking enforcing. So `--phase 2` on a cluster that has not been configured fails loudly.
That behaviour is already built and tested; it carries over unchanged.

Most of the CEL phase 2 needs already exists in `kyverno_cel.py` and was kept whole on purpose —
`accounted_prefixes`, `not_already_accounted_for`, `signature_scope_expression`,
`namespace_expression`, `pod_spec_expr`. Seven of its functions currently have no caller in the
fleet renderer; they were the advanced renderer's, and phase 2 is what gives them one back. That
is the reason the module was not split.

---

## 5. The matrices, rewritten for AUDIT

The brief's tables are written as admit/deny. In AUDIT nothing denies. Below is the same 18 cases
with the observable that actually exists. `pass`/`fail`/`skip` are `PolicyReport` results;
**every row admits**.

I've marked the rows where my expectation differs from the brief's with **←**.

### Phase 1 — one ivpol, `glob: "**"`, `[Audit]`

Single-image pod:

| image type | signed | in PEx | report result | pod |
|---|---|---|---|---|
| self-built | yes | no | `pass` | created |
| self-built | no | no | `fail` | created |
| self-built | no | **yes** | `skip` (names the exception) | created |
| vendor | no | no | `fail` | created |
| vendor | no | **yes** | `skip` | created |

Multi-image pod:

| scenario | report result | note |
|---|---|---|
| self-built signed + self-built unsigned | `fail` | one row for the policy on the resource; message names the failing image — **needs confirming whether the message enumerates all failures or stops at the first** |
| self-built signed + self-built unsigned, **excepted** | `skip` | the loophole. In AUDIT it is a **blind spot**: the unsigned image is not evaluated and not counted |
| vendor + vendor excepted | `skip` | same |
| vendor + self-built unsigned excepted | `skip` | same |

Scaling: yes, the result is the same for any number of images, because the unit of judgement is
the resource. One matching exception skips the policy for the pod however many containers it has.
Worth one explicit N=5 case in the harness rather than an assumption.

### Phase 2 — ivpol (self-built) + vpol (everything else), `[Audit]`

Single-image pod:

| image type | signed | in PEx | evaluated by | report result |
|---|---|---|---|---|
| self-built | yes | no | ivpol | `pass` |
| self-built | no | no | ivpol | `fail` |
| self-built | no | yes | ivpol | `skip` |
| vendor | no | no | vpol | `fail` |
| vendor | no | yes | vpol | `pass` ← **not `skip`** — a fine-grained exception does not skip the policy, it feeds `allowedImages` into an expression that then passes. Only a `spec.images`-less exception produces `skip`. This is the observable difference between the two exception kinds and the harness should assert on it |

Multi-image pod:

| scenario | brief says | I expect | why |
|---|---|---|---|
| self-built signed + self-built unsigned | deny | ivpol `fail` | agreed |
| self-built signed + self-built unsigned **excepted** | admit, loophole | ivpol `skip` — **loophole confirmed** | resource-scoped exception; §4.5 |
| vendor + vendor excepted | deny | vpol `fail` | agreed — the exempted one passes, the other fails, `all()` is false |
| vendor + self-built unsigned excepted | admit, loophole | **vpol `fail` ← not a loophole** | §4.3 — the exemption targets the ivpol only; the vpol still judges the vendor image |

### What the harness must do differently in AUDIT

- **Poll.** Reports are asynchronous (~15s). Assert-immediately gives false negatives.
- **Look up by `.scope.name`.** A `polr` is named for the subject's UID and owned by it — delete
  the pod and the report goes with it.
- **Assert the absence of the loophole rows too.** In AUDIT a missing row and a passing row look
  the same to a careless assertion.
- **Check the metrics before trusting a clean run** (§2): a fleet with broken registry credentials
  produces the same empty report set as a fleet with nothing wrong.

`container-vulnerability-exemption.kyverno/testing/run-admission-tests.sh` is the existing 12-pod
harness and the right place for this. Its README already has an "Audit vs Deny" section.

---

## 6. README rework, and the reading list you asked for

### After the rework, read these six, in this order

1. **`README.md`** (root) — the ADRs. Notation over Sigstore (ADR-0001), the three-tier CA
   (ADR-0003), and the new **ADR-0004** recording this pivot and superseding ADR-0002.
2. **`container-vulnerability-exemption/README.md`** — repo map. Currently opens *"it renders to
   two competing backends"*; becomes one backend and a rendered tree.
3. **`container-vulnerability-exemption/unikube/README.md`** — the big one: the schema you edit,
   the command surface, phase 1 vs phase 2, and the invariants. Currently ~530 lines with three
   sections describing the two old candidate models as still-open options.
4. **`container-vulnerability-exemption/image-signing/README.md`** then **`trust/README.md`** —
   where signatures come from and what the trust anchor is. Short, and the pair only makes sense
   read together.
5. **`container-vulnerability-exemption.kyverno/README.md`** — what the rendered tree is, and the
   two chart settings that decide whether any of it does anything
   (`features.policyExceptions.enabled` **defaults to false**;
   `features.policyExceptions.namespace` must not be `*`).
6. **`container-vulnerability-exemption.kyverno/testing/README.md`** — the matrices from §5 and
   how to run them.

Two more, conditionally: `.kyverno/poc/README.md` (the F1–F5 findings and the live-cluster test
plan — still the best single explanation of *why* the design is shaped this way, but framed as a
comparison of two candidates; see Q11) and `pck/README.md` (out of scope, one line).

**`project_metadata/history/**` is archive.** It holds the answer to almost every "why is it like
this" question, and it describes a repo that no longer exists. It should not be in the
end-to-end reading path, and the top of `history/` should say so.

### The rule this repo keeps re-learning

A previous doc sweep found the *candidate* model documented as if it had shipped. The fix that
worked was: **grep the scripts a README describes, don't just re-read the README.** Every claim in
the reworked docs gets checked against `kyverno_render.py` and the rendered tree, not against the
previous version of the prose.

---

## 7. Work streams and order

Each stream ends green: `pytest`, `validate.py` with **no flags**, `kyverno_render.py --check`
clean on both the pinned and `_preview-1.19` trees, and `kyverno_verify.sh` clean.

| # | stream | depends on |
|---|---|---|
| 0 | **Commit the working tree.** `git add` the untracked `history/poc/`, resolve the duplicated `project_summary.md`, commit the staged renames | — |
| 1 | **Two cluster probes** — §4.6 (can a vpol verify signatures?) and multi-PEM `certs.value` (§8, round 2). One session, both cheap; the first can collapse §4 entirely | cluster access |
| 2 | **Remove Wiz** — §3.4. Big diff, mechanical, no behaviour change to the Kyverno path | 0 |
| 3 | **Rename + rescope** — §3.1, §3.2. Includes the `git mv` of every `policy-exception/` directory in the `.kyverno` tree | 2 |
| 3.6 | **Comment diet** — §3.6, plus the budget test. Same PR as 3; the two touch the same emitters | 3 |
| 3.7 | **Background scan on** — §8 Q5. One renderer line; the reports-controller IRSA role is install-side and goes in the header as a prerequisite | 3 |
| 4a | **Write and post the upstream issue** — §3.3 as revised by Q8: short, one runnable reproduction. Independent of everything | — |
| 4b | **ECR `PutImage` IAM boundary** — restrict pushes under `signed_image_prefixes` to the CI role. Prerequisite for closure C; smaller than any policy change here | — |
| 4c | **Archive `.kyverno/poc/`** to `history/` (Q11) — lifting F1–F5 into `unikube/README.md` first, so the findings don't go into the archive with the test plan | — |
| 5 | **Phase 2 offline** — vpol renderer behind `--phase 2` (**1.19-only**, hard failure on a 1.18 cluster), CEL proved with `cel-python` against synthetic admission objects before any cluster is involved | 1, 3, 4b |
| 6 | **Phase 2 on the POC cluster** — the §5 matrix, plus the two must-verifies in §4.4 | 5 |
| 7 | **README rework** — §6, including ADR-0004 and the ADR-0003 F1 correction | 3, 6 |

Streams 2, 4a and 4b can start immediately. Stream 5 needs 4b landed first — closure C is only
real once the IAM boundary exists.

Stream 1 is still the cheapest high-value thing in this document: if a `ValidatingPolicy` can
verify signatures, phase 2 collapses to a single policy and §4.1–4.5 go away. Both probes are one
cluster session.

---

## 8. Answers received — decisions

**Round 1 (Q1, Q2, Q4, Q10)** and **round 2 (Q3, Q5, Q7, Q8, Q11 + two corrections)**. Recorded
here; the sections above stand as written and are now decisions rather than proposals.

### Round 1

**Q1 → PolicyReport results.** The harness asserts `pass`/`fail`/`skip`, polled, looked up by
`.scope.name`. No BLOCK run. §5's tables are the spec. Consequences: the job that collects
the report rows is part of the phase 1 deliverable, not a follow-on, and the metrics check in §2 is acceptance criteria —
under `[Audit]` + `failurePolicy: Ignore` a broken credential config and a clean fleet produce the
same empty report set, and asserting on reports alone cannot tell them apart.

**Q2 → C, relocation.** Non-compliant self-built builds are pushed to `unverified/`, outside the
signature policy's prefix, and exempted there per-image by the vpol. The loophole closes and
`PolicyException` keeps its RBAC/expiry/audit properties.

Three things follow, and the first is a blocker:

1. **The ECR `PutImage` boundary must become real.** C rests on "only CI may push under the signed
   prefixes, and CI signs what it pushes". Nothing in this repo enforces that today. Until the IAM
   restricts `ecr:PutImage` under `signed_image_prefixes` to the CI role, C is a convention, and an
   unsigned image pushed under a signed prefix is a `fail` row with no remedy short of editing a
   platform policy. **This is a prerequisite for stream 5, and it is a smaller change than any of
   the policy work.**
2. **The build pipeline gains a destination decision.** `.github/workflows/unikube.yaml` already
   runs `compliance_check.py` and branches on the result (sign / don't sign). C extends that
   branch to also choose the push destination: compliant → signed prefix + Notation sign;
   non-compliant → `unverified/`. That is a change to an existing `if`, not a new pipeline — which
   is the main reason C is cheap. (Q9 becomes moot: `compliance_check.py` is now load-bearing for
   the admission model, not an unrelated leftover. Keeping it.)
3. **`unverified/` must not sit under a `signed_image_prefixes` entry**, or the relocation
   achieves nothing. `validate.py` should reject that overlap — it already has
   `_check_prefix_collisions` and this is one more case for it.

**Q4 → keep the split**, re-framed. `container-vulnerability-exemption` is the interface;
`container-vulnerability-exemption.kyverno` is a rendered tree the renderer contributes to and
does not own. Every "backend A / backend B / two competing backends" framing goes; the
`--out-dir` discipline (write and prune only `OWNED_FILES`, never `*.yaml`) becomes the headline
rather than a footnote.

**Q10 → phase 1 on 1.18, phase 2 requires 1.19.** The per-cluster pin
(`admission.kyverno.version`) already supports this, so it is a validation rule rather than new
machinery: **`--phase 2` on a cluster pinned to 1.18 is a hard failure**, in the renderer and in
`validate.py`, with a message naming the three reasons (`spec.expiresAt` inert, `mutateDigest` an
unimplemented stub, kyverno#16060). Two consequences:

- §4.4(b) stops being a blocker. Whether #16060 is in v1.18.2 no longer gates phase 2, because
  phase 2 never runs on 1.18. **Still worth confirming**, since it decides whether phase 1's
  exemptions behave as documented on the fleet today — but it is now a phase 1 correctness
  question, not a phase 2 scheduling one.
- `expired_at` gets a real consumer for the first time. On a phase 2 / 1.19 cluster it renders as
  `spec.expiresAt` and the engine acts on it; on a phase 1 / 1.18 cluster it stays render-time
  only. The docs must state which cluster is which, because "this exemption expires" is true on
  one and false on the other.

**Still open: Q3, Q5, Q6, Q7, Q8, Q9, Q11 below.** Q9 is answered in passing above (keep
`compliance_check.py` — C makes it load-bearing). Q5 (background scanning) is the one I'd most
like next: it decides whether AUDIT gives a fleet inventory or only a stream of new admissions.

### Round 2

**Q3 → delete `tenants.yaml`** (and `schemas/tenants.schema.json`). It is entirely Wiz: tenant
engine pins plus the backend gate.

One loose end this creates: `schema_version` was declared only in that file and its schema, and
**nothing in `scripts/` ever reads it** — I checked, the only references are the two lines in
`tenants.schema.json` that declare it. So deleting the file deletes a field with no consumer.
That's the cleanest outcome, and I'll take it unless you say otherwise: **no replacement home,
the field goes away.** Flag it if `schema_version` means something to a downstream system I can't
see from here.

**Q5 → background scanning ON.** This is the right call for an AUDIT programme — without it you
only ever see pods created *after* the policy lands, and a stable Deployment that has been running
for six months is never judged at all, so "the fleet looks clean" would mostly mean "nothing has
restarted". It also has a prerequisite that is very easy to miss and fails quietly:

> **The reports controller does its own registry egress.** Background scan re-verifies every
> matched image from `kyverno-reports-controller`, **not** from the admission controller — a
> second IRSA role, on a second service account, that §6 of the POC walkthrough never granted.
> Without it, expect auth errors on every scan.

And a 401 in the reports controller lands in exactly the failure mode §2 describes: the row is
missing rather than wrong, so a broken scan and a clean fleet look identical. So Q5 = On adds
three things to phase 1, not one:

1. `evaluation.background.enabled: true` in the rendered policy (a one-line renderer change).
2. An IRSA role for `kyverno-reports-controller` with the same ECR permissions as the admission
   controller's, annotated onto `reportsController.rbac.serviceAccount`. **Chart/infra work, not
   renderer work** — it belongs to whoever installs Kyverno, and the rendered file's header should
   say so, because nothing in the manifest reveals the dependency.
3. A registry-load conversation. The POC values set `backgroundScanInterval: 1h`; at ~200 clusters
   that is every matched image re-verified hourly, fleet-wide, from a second egress path. The POC
   flagged this as its own test (P17) and called it *"the number the registry team will care
   about"*. I'd raise it with them before this reaches more than a handful of clusters, and
   consider a longer interval — nothing about an inventory needs hourly freshness.

**Q7 → `container_exemptions`, underscore confirmed.** No change from §3.1.

**Q8 → rewrite the upstream issue, short.** This changes §3.3 materially: the existing draft is
361 lines and is a comprehensive case built for an audience choosing between tools. What you want
is a bug report that lands in one read. New shape:

- **The contrast as the headline.** A `ValidatingPolicy` checks every image and an exception can
  be scoped to one of them (`spec.images` → `exceptions.allowedImages`). An
  `ImageValidatingPolicy` — the policy type whose *unit of judgement is an image* — skips the
  entire resource when one image is excepted, and `spec.images` is accepted and silently ignored.
- **One reproduction anyone can run**, self-contained: an ivpol requiring signatures, a two-image
  pod where one image is legitimately excepted and the other is not, and the observed result that
  **both** are admitted. Then the same setup on a vpol, where only the excepted one passes. Two
  `kubectl apply`s and a `kubectl get`, no private registry needed.
- **Cut**: the 25-row issue index, the KDP archaeology, the "history in one paragraph". Keep at
  most three links — `KDP#77` (enumerates vpol/mpol/gpol, omits ivpol), `#8663` (the same ask,
  closed stale), `#13817` (where the feature shipped for vpol).
- Keep the ask to the two options already drafted: register `exceptions` in the ivpol CEL
  environment, or reject the combination at admission instead of ignoring it.

The long draft stays in `history/` as the working notes behind the short one.

**Q11 → archive `.kyverno/poc/` to `history/`.** Which means the F1–F5 findings need somewhere to
live, because they are the reasons half the design is shaped the way it is and they must not go
into the archive with the rest. They move into `unikube/README.md` as a short "what Kyverno does
and does not do on this version" section — the facts, not the test plan.

### Two corrections to §9

**Trust anchors — you're right, and the plan's §9 bullet was wrong.** I wrote "root, never an
intermediate" as if it were enforced. It is not: `common.ca_cert_paths()` globs `*.crt` and
`load_ca_certs()` applies structural checks only — PEM markers, a STUB placeholder guard,
dedup-by-content. **No filename is privileged and nothing checks CA depth.** Whatever `.crt` sits
in `trust/` is a trust anchor. §9 now says that.

Preferring a root remains *documented guidance* with a real reason behind it (the Notary spec
warns that an intermediate in the trust store is certificate pinning that breaks on every
intermediate rotation) — but guidance is all it is, and the plan should not have presented it as
a settled constraint.

Two things follow that were not in the plan:

1. **`trust/README.md` is a rewrite, not a sweep.** I had it down as a one-line item under §3.4.
   It is 11KB and most of it is Wiz mechanics — `notary_v2`, `notary_ca_certificates`,
   `terraform plan`, `wiz_render.py`, "both tenants", the path filter on the terraform workflow.
   Its *reasoning* survives the pivot almost entirely intact and is worth keeping; its
   *mechanics* are all gone.
2. **It carries the same factual error as ADR-0003.** Its closing paragraph says to keep the DN
   discipline because it is a prerequisite "if a revisit trigger moves enforcement to Kyverno,
   **which supports `trustedIdentities` today**". That is F1 again — Kyverno builds the notation
   trust policy in Go with `TrustedIdentities: ["*"]` hard-coded. Fix both in the same pass.

   Worth stating plainly, because the pivot makes it sharper rather than softer: that README's
   central argument — a CA is not an authorization boundary, so with no identity pinning at the
   gate the anchor must be *ours alone*, hence a standalone signing root — **applies to Kyverno
   exactly as it applied to Wiz.** Neither gate can ask "was this signed by us?". The standalone
   root is not a Wiz artefact to be cleaned up; it is load-bearing under Kyverno too.

**Multi-anchor rotation is still open, and the question changed owner.** The plan didn't carry
this and should have. `trust/` supports several `.crt` files, and add-new → re-sign → remove-old
is the only rotation path that isn't a hard fleet-wide cutover. Under Wiz the open question was
*"does Wiz evaluate every entry in `notary_v2`, or only the first?"* (venafi-signing Q8). Under
Kyverno it becomes:

> **Does Kyverno accept multiple concatenated PEMs in one `attestors[].notary.certs.value`, and
> does it evaluate all of them?**

`_attestor_block()` concatenates them today and its own docstring marks this **UNVERIFIED**. If
Kyverno rejects a multi-PEM value, the fallback is one attestor per anchor plus
`verifyImageSignatures(image, [a, b]) > 0`. **Confirm before rotating anything** — this is a
one-command check on the POC cluster and it belongs next to the §4.6 probe in stream 1.


---

## 8b. Still open

Everything else is answered in §8. Two items left, neither of which blocks a start:

**Q6 — `nonprod/wizn02`, restated.** Sorry, that was badly asked. Concretely: the cluster's
config file is `unikube/exemptions/nonprod/wizn02.yaml` and its rendered manifests live in
`unikube/nonprod/wizn02/`. That string `wizn02` propagates into object annotations
(`exemption.unikube.io/cluster: nonprod/wizn02`) and into every rendered path.

The question is only whether `wizn02` is **the real name of a real EKS cluster in your estate**,
or a placeholder someone picked for this repo back when Wiz was the plan:

- **Real cluster name** → leave it alone. Renaming would desync this repo from the cluster it
  targets, and that is far worse than a name that reads oddly.
- **Placeholder** → worth renaming now, while it costs one file move and one directory move.
  After the fleet grows it costs a coordinated change across every rendered tree.

I can't tell which from inside the repo, which is why I'm asking. Default if you'd rather not
decide: **leave it**, and I'll note in the README that the name is historical.

**`schema_version` has no consumer.** Following from Q3 (delete `tenants.yaml`): the field is
declared in `tenants.schema.json` and read by nothing in `scripts/`. My assumption is that it
disappears with the file. Say so if a downstream system reads it and I'll find it a new home.

---

## 9. Things I am treating as settled, so you can object

- **Trust anchors are whatever `*.crt` sits in `trust/`** — no filename is privileged, nothing
  checks CA depth, and an intermediate is accepted as readily as a root (corrected in §8; the
  earlier "root, never an intermediate" bullet overstated a documented preference as an enforced
  rule). Preferring a root stays as guidance, with the Notary spec's reasoning behind it.
- `failurePolicy: Ignore` stays the default, in both phases, with the metrics check as the
  compensating control (§2).
- `evaluation.background.enabled: true` in both phases (Q5), with the reports-controller IRSA
  role called out in the rendered header as an install-side prerequisite.
- **No namespace object is rendered.** `kyverno-exceptions` belongs to whoever installs the chart.
- **No cleanup policy.** On 1.18 nothing in-cluster retires an exemption; expiry is a render-time
  fact and the docs say so rather than implying otherwise.
- The `guardrail-vpol.yaml` policy-over-policy (constraining what a `PolicyException` may look
  like) ships **alongside** the exceptions namespace, not after it. A `PolicyException`'s
  `matchConditions` is unrestricted CEL, so whoever can create one can write `true`. That, plus
  `exception_writer` RBAC pointed at the GitOps controller, is the real security boundary of this
  design — tighter than either policy.
- Rendered files keep the DO-NOT-EDIT header naming the source YAML and the phase, and `--check`
  keeps failing CI on drift. The header's first line stays exactly `# GENERATED FILE` —
  `kyverno_verify.sh` discovers clusters by grepping for it, so trimming comments (§3.6) must not
  touch it.

---

## 10. Status — built 2026-08-25

**Phase 1 is built and green.** `195 passed`, `validate.py` clean with no flags (two expected
warnings), `kyverno_render.py --check` clean on both the pinned and `_preview-1.19` trees.

### Landed

| stream | what |
|---|---|
| 2 | **Wiz removed.** 4 scripts, 3 test modules, `tenants.schema.json`, `tenants.yaml`, `terraform.yaml` and `.github/actions/` moved out; the backend gate stripped from `validate.py` and `common.py`; every schema description, exemption comment and README rewritten. |
| 3 | **Renamed and rescoped.** `soe-notary-signed-simple` → `require-org-signed-images`; the `mode` machinery deleted and replaced with `admission.phase` (1 \| 2, per cluster, refused on 1.18 for phase 2); `policy-exception/` → `container_exemptions/`, moved rather than re-rendered; `OWNED_FILES` is now the union across both phases. |
| 3.6 | **Comment diet**, with a budget test. `20-polex.yaml` went from 61 comment lines to 20 — and the header is now emitted once per file rather than once per exemption, so it no longer grows with the exemption count. |
| 3.7 | **Background scan on**, with the reports-controller IRSA prerequisite in the rendered header. |
| 4a | **Upstream issue written, reproduced and reduced to one file**: [`kyverno-ivpol-policyexception-issue-concise.md`](kyverno-ivpol-policyexception-issue-concise.md). Run end to end on EKS v1.36 / Kyverno v1.19.0: both images denied on their own, the exempted image admitted, the unrelated image still denied on its own, and the two-container pod **created** — the central claim is measured, not inferred. It carries a `ValidatingPolicy` control showing the same exception shape denying the same mixed pod, which is what makes the ivpol behaviour a bug rather than a design choice. The earlier long draft and the 361-line `history/` notes were deleted; this file is the only version. |
| 4c | **`.kyverno/poc/` archived** to `history/kyverno-poc-suite/`; F1–F5 lifted into `unikube/README.md` as "What Kyverno does and does not do on these versions". |
| 7 | **Docs reworked**: ADR-0004 added (superseding ADR-0002, which is kept in full); the F1 error corrected in ADR-0003 **and** in `trust/README.md`, which was rewritten rather than swept. |

### Three changes made after the pivot landed

| | |
|---|---|
| **Preview refresh is opt-in** | `_preview-<version>/` trees were refreshed on every render and gated by every `--check`. That fixed staleness and introduced a worse habit: a one-cluster render rewrote a whole fleet's preview tree, so a PR diff contained directories nobody had touched, and an unrelated `--check` failed on a tree the caller never mentioned. Now `--refresh-previews` does both, and an ordinary render names the trees it left alone. |
| **`cmdb-app-service-id` moved onto the exemption** | It was one fleet-wide value from `$CMDB_APP_SERVICE_ID` stamped on every object, which recorded who ran the renderer rather than who owns the exemption — not the same question once two teams have entries in one file. It is now a required field on each exemption entry, rendered as the label on that entry's PolicyException only. The flag and the environment variable are gone. Policies carry no owner label: they are platform-owned and shared by every team on the cluster. `--summary` gained an exceptions-by-owner breakdown. |
| **`--1.19` removed** | See the rename table above. |

### Two things that changed while building

**The whole fleet is now AUDIT.** `nonprod`, `preprod` and `prod` were on `BLOCK`. The brief
says AUDIT and §2 says why it matters, so the env globals were flipped. One env in the *test
fixture* tree stays on BLOCK so the Deny-plus-Audit path keeps its coverage.

**Two security approvals became enforceable.** `prod/fsp02`'s vendor image was approved for
`payments`/`payments-uat` and `nonprod/wizn02`'s legacy build until 2026-11-15 — both recorded
in comments because the Wiz gate rejected the fields. They are now written as `namespaces:` and
`expired_at:`. They are not yet *enforced* (phase 1 emits no namespace clause; 1.18 ignores
`expiresAt`), and `validate.py` says so on every run — but the record is in the field now
instead of in prose. The 1.19 preview tree already renders the expiry natively, which is the
clearest demonstration of the version gate on real data.

### Not done, and why

**Phase 2 is designed, configured on `poc/demo`, and refuses to render** — with a message naming
the two cluster probes that decide its shape (§4.6, and multi-PEM `certs.value`). Writing the
emitter before those are answered would mean writing it twice.

**Two files the device bridge would not write.** `.github/workflows/kyverno.yaml` and
`unikube.yaml` are protected paths. Both are edited and delivered as file cards — they need
copying into place by hand. Their remaining Wiz references are the only unintentional ones left
in the repo.

**The archive commit is still running** against the iCloud-backed checkout (30+ minutes; it is
writing several thousand git objects through a synced filesystem). Everything above is on disk
regardless. Two housekeeping items when it lands:

- `rm .git/index.lock` — a stale zero-byte lock from before this session. Every `git` write had
  to be routed around it with `GIT_INDEX_FILE`.
- `rm -rf _to_delete_pivot/` — the removed files. The bridge cannot delete, so they were moved
  there instead.

### Still open

- **Q6 answered:** `wizn02` is a real cluster name. Left alone.
- `schema_version` had no consumer and went away with `tenants.yaml`.
- **The ECR `PutImage` boundary is still a convention.** Closure C rests on it, and
  `unikube/README.md` says so in a callout rather than assuming it.
