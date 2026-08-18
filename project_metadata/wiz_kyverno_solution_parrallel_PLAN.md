# Implementation plan — parallel Wiz / Kyverno backends

**Brief:** [`wiz_kyverno_solution_parrallel.md`](wiz_kyverno_solution_parrallel.md) · **Date:** 2026-08-18
· **Supersedes nothing** — it extends [`terraform-rework_PLAN.md`](terraform-rework_PLAN.md) and
[`ignore_rules-rework_PLAN.md`](ignore_rules-rework_PLAN.md) with a second backend.

The shape of the change: `container-vulnerability-exemption` stays the one interface tenants
edit; it now renders into **two** backends that are deliberately kept comparable —
`container-vulnerability-exemption.wiz` (mature, terraform, one tenant API) and
`container-vulnerability-exemption.kyverno` (new, in-cluster CRDs, ~200 etcds). The exemption
YAML is the single source of truth for both.

---

## 1. Decisions taken up front

These were settled before planning; everything below follows from them.

| # | Decision | Consequence |
|---|---|---|
| D1 | **Render both Kyverno versions**, 1.18.2 and 1.19.0-rc.4, version-pinned per env with a per-cluster override | The fleet is on 1.18.2 today and moves to 1.19 later. A cluster moves version in a one-line PR whose diff shows exactly what changes. Every generated file carries a header comment naming the version-specific behaviour. |
| D2 | **One `PolicyException` per exemption entry** | Kyverno has no per-tenant object cap, so the Wiz aggregation compromise is not repeated. Per-entry expiry, ticket and approver survive into the object. |
| D3 | **Schema gains optional `operator` and `expired_at`** | Kyverno honours both. `validate.py` **errors** if a file uses them while the Wiz backend is enabled, so a tenant cannot write something Wiz silently cannot express. |
| D4 | **Rendered manifests are committed**, one directory per cluster | `kubectl apply -f <dir>` works, and an exemption change is a reviewable manifest diff. |
| D5 | **`enforcement` and `failurePolicy` are decoupled** | `enforcement` drives `validationActions` only. A new optional `admission.failure_policy` (`Ignore`\|`Fail`, default `Ignore`) drives `failurePolicy`, because fail-closed is the highest-blast-radius setting in the design (POC P10) and should not be chosen by a field that never mentions it. |
| D6 | Scope = **render + validate + CI + documented delivery** | No ArgoCD/Flux layer is built; the ADR has not chosen a delivery tool. How manifests reach ~200 clusters is written down, not implemented. |

---

## 2. Target tree

```
container-vulnerability-exemption/                 # INTERFACE — tenants edit here
  trust/*.crt                                      # Notary trust anchors (unchanged, security-owned)
  image-signing/                                   # ALL cert-gen + signing lives here now
    README.md          <- (2) grows from a 1-line stub into the full signing guide
    gen_signing_certs.sh  sign-image.sh            # already moved; docs must follow
  unikube/
    exemptions/<env>/{global,<CLUSTER>}.yaml       # unchanged shape + 3 optional fields
    schemas/                                       # + operator, expired_at, failure_policy, kyverno.version
    scripts/
      common.py  validate.py  render.py  mock_plan.py  check_exemption.py  compliance_check.py
      render_kyverno.py        <- NEW
      kyverno_cel.py           <- NEW (the CEL builder, kept separate so it is unit-testable)
      verify_manifests.sh      <- NEW (kubeconform + kyverno CLI against both CRD versions)
    tests/                                         # + test_render_kyverno.py, test_kyverno_cel.py
    README.md          <- (1) COMPACT: commands only
  pck/                                             # untouched stub
  .github/workflows/{terraform.yaml, unikube.yaml, kyverno.yaml <- NEW}

container-vulnerability-exemption.wiz/             # BACKEND A (mature)
  README.md            <- (3) rename/path fixes only
  terraform/...

container-vulnerability-exemption.kyverno/         # BACKEND B (new)
  README.md            <- (4) NEW — the object model and how it differs from Wiz
  unikube/<env>/<cluster>/                         # RENDERED, COMMITTED
    00-ivp-soe-signed.yaml
    10-ivp-catchall.yaml                           # 1.18 only; 1.19 uses `required: true`
    20-polex-<scope>-<name>.yaml                   # one per exemption entry
    90-cleanup-expiry.yaml                         # 1.18 only; composes expiry
  poc/                                             # evidence-gathering suite, unchanged
  docs/kyverno-1.18-vs-1.19.md                     # NEW — the version delta, in one place

project_metadata/project_summary.md                <- (5) rewritten for two backends
```

---

## 3. The crux: how one exemption becomes Kyverno objects

This is the part that is not a mechanical translation. Wiz suppresses a **finding on an
image**; Kyverno's `PolicyException` skips a **policy for a resource**. Four consequences
drive the whole renderer.

### 3.1 An exception may only ever reference the catch-all policy

`policyRefs` names **`deny-unverified-images`** and never `soe-notary-signed`. Hard invariant,
asserted in a unit test.

The reason: if an exception could reference the signature policy, an exemption on a vendor
image would also switch off signature verification for any SOE image in the same pod — an
exemption would become a way to admit an unsigned self-built image. Referencing only the
catch-all keeps the two questions separate, which is exactly the separation the Wiz model has
for free (an ignore rule cannot disable the image-integrity validator).

### 3.2 The "other containers" guard must cover the whole cluster's exemption set

The POC's `polex-vendor.yaml` guards correctly for one exemption:

```cel
object.spec.containers.exists(c, c.image == 'docker.io/library/nginx:1.27.3') &&
object.spec.containers.all(c,
  c.image == 'docker.io/library/nginx:1.27.3' ||
  c.image.startsWith('container-soe.registry.domain/'))
```

The second clause exists because an exception skips the policy for the **pod**, so without it a
pod containing the exempted nginx *plus* an arbitrary unsigned image would have the catch-all
skipped entirely. Correct — and it breaks the moment there are two exemptions.

> Pod runs vendor-A and vendor-B, both individually exempt. A's `all()` clause fails (B is
> neither A nor SOE), so A does not match. B's fails symmetrically. Neither exception applies
> and the pod is **denied**, despite every image in it being approved.

**Resolution:** the guard clause is rendered against the **union of every exemption in scope
for that cluster** (env-global + cluster-own), not just the entry's own value:

```cel
# entry's own selector — what makes THIS exception the one that matched
(<SELF>) &&
# guard — every image in the pod is either exempt on this cluster or an SOE image the
# signature policy is separately responsible for
all_images.all(i, <ANY_EXEMPT>(i) || i.startsWith('container-soe.registry.domain/'))
```

The cost, and it must be in the README: **the renderer needs the cluster's full merged
exemption set to render any single file**, and adding one exemption rewrites the guard clause
in every `polex-*.yaml` for that cluster. Diffs are churny. The alternative — self-only guards,
accepting that multi-exempt pods are denied — is strictly worse and is rejected here, but is
recorded in the Kyverno README so nobody "simplifies" it back.

### 3.3 All three container lists, and the pod-controller shape

`all_images` is built once, in `kyverno_cel.py`, as:

```cel
object.spec.containers +
object.spec.?initContainers.orValue([]) +
object.spec.?ephemeralContainers.orValue([])
```

`?field.orValue([])` is Kyverno's own idiom (`pkg/cel/compiler/images.go`), so it is known to
compile. **List concatenation on dyn-typed fields is the risky part** — the POC's catch-all
deliberately used two separate `.all()` calls to avoid it. The builder therefore emits the
separate-`.all()` form by default and the concatenated form only behind
`--cel-style=concat`, so if concatenation turns out not to type-check on 1.18 the fix is a
flag, not a rewrite.

**⚠ Open, must be answered by the POC before this ships:** a `Deployment` admission request
carries the pod spec at `object.spec.template.spec`, not `object.spec`. IVP autogen covers the
*policy*; whether it rewrites a `PolicyException`'s `matchConditions` is unverified. The
renderer emits a shape-tolerant prefix —

```cel
(has(object.spec.template) ? object.spec.template.spec : object.spec)
```

— bound to a local, which is correct either way, and POC test **5.12 must be extended to
create a Deployment with an exempted image** and confirm the exception fires. If autogen
already handles it, the prefix is harmless; if it does not, the prefix is the fix.

### 3.4 Operator mapping, and CEL-literal safety

| `operator` | Wiz | Kyverno CEL |
|---|---|---|
| `starts_with` (default) | `image_name.starts_with` | `i.startsWith('<v>')` |
| `equals` | *unsupported — validate.py errors* | `i == '<v>'` |

`matches_regex` is **not** reintroduced. CEL has `.matches()`, but a regex in the admission path
is a footgun with no Wiz equivalent, and the two-backend comparison is worth more than the
expressiveness.

`validate.py` gains a CEL-literal check: `image_value` may not contain `'` or `\`, since values
are interpolated into single-quoted CEL literals. The existing `_REGEXY` check already blocks
most of the surrounding hazards; this closes the injection one.

### 3.5 Expiry — and the failure mode that must not happen

| version | mechanism |
|---|---|
| **1.19** | `spec.expiresAt` (RFC3339) + `spec.properties.{reason,ticket,approved-by}` |
| **1.18.2** | label `exemption.unikube.io/expires: YYYY-MM-DD` + a rendered `ClusterCleanupPolicy` (`90-cleanup-expiry.yaml`); ticket/approver as annotations, same keys, so the migration is mechanical |

**The renderer must never emit `spec.expiresAt` into a 1.18 bundle.** F5: a v1.19 manifest
applies cleanly on 1.18.2 and *silently drops* `expiresAt` — an exemption that applies, works,
and never expires. This is asserted twice: a unit test on the renderer, and `verify_manifests.sh`
validating each rendered tree against the CRD schema of the version it was rendered for.

The Wiz side is unchanged and still has no expiry, by design (one aggregated rule, one
`expired_at`, nothing useful to do with it). Which is why D3 makes `expired_at` a **hard error
when the Wiz backend is enabled** rather than a field Wiz quietly ignores.

### 3.6 Backend capability gating

So that D3 does not simply forbid `expired_at` for the entire bake-off, capability is declared,
not assumed. `unikube/exemptions/tenants.yaml` gains:

```yaml
backends: [wiz, kyverno]        # repo-level; which backends must be able to render this tree
```

`validate.py --backend <name>` (default: every enabled backend) rejects a field no enabled
backend supports. Drop `wiz` from the list and `expired_at` becomes legal; the Wiz workflow's
own validate step passes `--backend wiz` and keeps failing loudly, so the gate cannot be
bypassed by editing one list.

### 3.7 Trust anchors — the fan-out tax, stated

The IVP embeds the trust root in `attestors[].notary.certs.value`. With committed manifests
across ~200 clusters, **a CA rotation is a ~200-file diff** — the same event that is a single
in-place update of one Wiz validator. That asymmetry is the sharpest illustration of ADR-0002
rationale 2 this exercise will produce, and it belongs in the comparison rather than being
engineered away silently.

Two things follow:

1. The renderer supports the POC's **`expression:` + ConfigMap** variant behind
   `--trust-source=configmap`, which reduces rotation to one ConfigMap per cluster. Worth
   measuring; not the default until the POC confirms it works with the real chain.
2. **Unverified:** whether `certs.value` accepts multiple concatenated PEM blocks (needed for
   add-new → re-sign → remove-old rotation, which `notary_v2`'s list gives us on the Wiz side).
   The renderer concatenates and a POC test must confirm. If it does not, multi-anchor rotation
   needs multiple `attestors[]` entries and `verifyImageSignatures(image, [a, b]) > 0`.

---

## 4. Schema changes

`exemption.defs.json`:

```jsonc
"operator":   { "enum": ["starts_with", "equals"], "default": "starts_with" },  // optional
"expired_at": { "type": "string", "format": "date" }                            // optional, RFC3339 date
```

`cluster.schema.json` / `global.schema.json` — `admission` grows:

```jsonc
"failure_policy": { "enum": ["Ignore", "Fail"] },     // D5; default Ignore
"kyverno":        { "version": { "enum": ["1.18", "1.19"] } }   // default 1.18; cluster overrides env
```

Resolution follows the existing `resolve_enforcement` precedence exactly — cluster file → env
`global.yaml` → default — so there is one implementation of precedence in `common.py` and three
callers, not three rules.

`tenants.yaml` gains repo-level `backends: [...]` (§3.6). It does **not** gain a Kyverno version
pin: the Wiz tenant is not the sharding axis for Kyverno, the cluster is.

**Back-compatibility:** every new field is optional with a default equal to today's behaviour.
No existing exemption file changes, and `render.py`'s output is byte-identical before and after
— asserted by a golden test, because a spurious tfvars diff would show up as a fleet-wide Wiz
plan.

---

## 5. Work breakdown

### Phase 0 — hygiene (no behaviour change)

- [ ] Sweep every `container-vulnerability-exemption.tf` reference → `.wiz`. Present in:
      `project_summary.md` (×6), `unikube/README.md` (§5 `ENGINE=`, `local_tf.sh` default),
      `container-vulnerability-exemption/README.md`, `.wiz/README.md` title, `local_tf.sh`.
- [ ] Fix signing-script paths: `scripts/gen_signing_certs.sh` / `scripts/sign-image.sh` →
      `image-signing/`. Present in `unikube/README.md` §3/3b, `.wiz/README.md` "Local plan",
      `project_summary.md` follow-ups.
- [ ] Fix `poc/README.md`'s stale `../wiz/container-vulnerability-exemption/trust/ca.crt` and
      `../README.md#adr-0002` (the ADR is the *repo-root* README, not the kyverno repo's).
- [ ] Move `container-vulnerability-exemption.kyverno/debug.sh` → `unikube/scripts/debug_base_layers.sh`.
      It debugs `compliance_check.py`'s layer rule and has nothing to do with the Kyverno backend;
      leaving it there implies the backend owns compliance, which it does not.
- [ ] Delete the committed `unikube/.venv/`, `__pycache__/`, `.pytest_cache/`, `out/pki/` and
      `.DS_Store` noise; confirm `.gitignore` covers them.
- [ ] `container-vulnerability-exemption.kyverno/unikube/{nonprod/wizn02,prod/fsp02}.yaml` are
      copies of the *exemption* files, not rendered manifests. Delete — they are placeholders
      that will be replaced by rendered directories.

### Phase 1 — shared contract

- [ ] `exemption.defs.json`, `cluster.schema.json`, `global.schema.json`, `tenants.schema.json`
      per §4.
- [ ] `common.py`: `resolve_failure_policy`, `resolve_kyverno_version`, `exemption_specs`
      carries `operator` + `expired_at`, `enabled_backends()`.
- [ ] `validate.py`: backend gating (§3.6), CEL-literal safety (§3.4), `expired_at` must be a
      future date at merge time, `operator: equals` values must not look like prefixes-with-tags
      that will never match.
- [ ] `check_exemption.py`: `matches()` honours `operator`. **This is the correctness-critical
      one** — its job is to agree exactly with what the backend will do, and today it hardcodes
      `startswith`. An `equals` exemption would otherwise pass CI and be rejected at admission.
- [ ] `render.py` (Wiz): unchanged output, but must *reject* rather than ignore an
      `equals`/`expired_at` entry, so the failure is at render time and not in a Wiz plan.

### Phase 2 — the Kyverno renderer

- [ ] `kyverno_cel.py` — pure functions, no I/O: `selector(operator, value)`,
      `all_images_expr(style)`, `pod_spec_prefix()`, `exception_expression(entry, cluster_set)`.
      Separate module because the CEL is the risky artefact and must be testable without
      touching the filesystem.
- [ ] `render_kyverno.py`:
      - `--cluster <env>/<cluster>` (default: whole fleet)
      - `--kyverno-version 1.18|1.19` (default: resolved per cluster)
      - `--out-dir` (default: `../../container-vulnerability-exemption.kyverno/unikube`)
      - `--check` — render to memory, diff against the committed tree, exit 1 on drift (CI)
      - `--summary` — the `mock_plan.py` analogue: objects per cluster, exception count,
        which policies each references
      - `--diff-versions <env>/<cluster>` — 1.18 vs 1.19 unified diff for one cluster, which is
        the artefact that answers "what actually changes when we upgrade"
      - `--trust-source inline|configmap` (§3.7)
- [ ] Generated-file header block, on every file: `DO NOT EDIT`, source YAML path, renderer
      version, Kyverno version, and the version-specific caveat that applies to that file
      (F3 for the catch-all, F4 for 1.18, F5 for the expiry files).
- [ ] Object naming: `soe-notary-signed`, `deny-unverified-images`,
      `polex-<scope>-<name>` where scope ∈ {`global`, `own`}. All DNS-1123; `name` is already
      `^[a-z0-9-]{1,10}$` so no sanitisation is needed, but assert it.
- [ ] **Env-global exemptions are copied into every cluster in the env.** There is no shared
      object across clusters — that is the fan-out, and the renderer should not pretend
      otherwise. `--summary` reports the multiplier (`N entries → N × M objects`).

### Phase 3 — validation harness

Verified available in this environment: `kubeconform` v0.8.0, both CRD manifests
(`v1.18.2`, `v1.19.0-rc.4`) fetch cleanly from the Kyverno repo, `cel-python` installs.
**No Docker daemon here, so no `kind` cluster** — live admission testing stays with the POC.

- [ ] `verify_manifests.sh`: pull both CRDs → convert to JSON Schema → `kubeconform -strict`
      each rendered tree against **the version it was rendered for**. This is what catches the
      F5 silent-drop class of bug.
- [ ] `tests/test_kyverno_cel.py` — evaluate generated expressions with `celpy` against
      synthetic admission objects:
      | case | expect |
      |---|---|
      | pod with one exempt image | exception matches |
      | pod with two *different* exempt images | **both** match (§3.2 regression test) |
      | exempt image + unsigned vendor image | no match → catch-all denies |
      | exempt image + SOE image | matches; SOE image still verified by the other policy |
      | exempt image in `initContainers` only | matches |
      | `equals` exemption, image with a different tag | no match |
      | Deployment-shaped object | matches (§3.3) |
- [ ] `tests/test_render_kyverno.py` — golden files, the `policyRefs` invariant (§3.1), no
      `expiresAt` in any 1.18 output, `--check` detects drift.
- [ ] Optional if the CLI supports IVP offline: `kyverno apply` over the rendered tree with the
      POC's fixture pods. Nice to have; kubeconform + celpy is the floor.

### Phase 4 — commit the rendered tree

- [ ] Render all clusters at their pinned version (1.18 everywhere initially) and commit.
- [ ] Additionally commit `nonprod/wizn02` at 1.19 under a clearly-marked
      `_preview-1.19/` sibling, so the upgrade delta is visible in the repo rather than only
      reproducible from a flag.
- [ ] `docs/kyverno-1.18-vs-1.19.md` — F1–F5 restated as *what it means for these manifests*,
      with the concrete diff.

### Phase 5 — CI

- [ ] `.github/workflows/kyverno.yaml`, same path filters as `terraform.yaml`
      (`unikube/exemptions/**`, `unikube/schemas/**`, `trust/**`):
      `validate.py --backend kyverno` → pytest → `render_kyverno.py --check` → `verify_manifests.sh`
      → PR comment with the object delta (the `--summary` analogue of the tfvars plan counts).
- [ ] `terraform.yaml`: add `--backend wiz` to its validate step.
- [ ] **Repo-boundary decision to confirm (see §7 Q1):** the interface and backend are separate
      repos in the ADR but sibling directories here. `--check` assumes one checkout. If they
      really are separate repos, CI renders and opens a PR against the backend repo, and *that*
      merge is the Kyverno equivalent of `terraform apply`. Documented either way.

### Phase 6 — documentation

| # | File | Change |
|---|---|---|
| 1 | `unikube/README.md` | **536 → ~150 lines.** Keep: model summary (short), layout, file schema, and the command surface — venv, `validate.py`, `render.py`, `render_kyverno.py`, `mock_plan.py`, `check_exemption.py`, `compliance_check.py`, `pytest`, `local_tf.sh`. Move all PKI/signing/verify prose (§3, 3b, 3c ≈ 170 lines) to `image-signing/README.md`. Move backend object detail to the two backend READMEs. Link, don't restate. |
| 2 | `image-signing/README.md` | Stub → the full guide: `gen_signing_certs.sh` both modes, the three-tier PKI and why the anchor is the **root**, `signing-chain.crt` vs `signing.crt`, `sign-image.sh` env contract and the notation config-dir backup/restore behaviour, the local-registry traps (port 5000, `127.0.0.1` vs `localhost`, `insecureRegistries`), and the `notation verify` walkthrough against the **committed** `trust/ca.crt`. Points to `image-signing-101.md` and `notation-signing.md` for theory. |
| 3 | `.wiz/README.md` | Rename + paths (Phase 0). Add a short "how this compares to the Kyverno backend" table. |
| 4 | `.kyverno/README.md` | **New.** Object model per cluster; the four consequences in §3 (especially the §3.2 guard and why it is not simplifiable); enforcement/failurePolicy mapping; version matrix and how to move a cluster; `kubectl apply -f` instructions; the trust-anchor fan-out (§3.7); what is *not* covered — Kyverno does not scan, so a `PolicyException` answers "may this be admitted", never "do we accept this CVE"; pointer to `poc/`. |
| 5 | `project_summary.md` | Rewritten: one interface, two backends, the comparison table, both change-flows, and the honest statement that ADR-0002 rationales 1 and 2 are untouched by any of this. |
| 6 | repo-root `README.md` (ADR) | Correct ADR-0003's claim that Kyverno "supports [identity pinning] today" — it does not (F1, `TrustedIdentities: ["*"]` hardcoded). Retire ADR-0002 rationale 3 (F5). Both corrections stand regardless of which backend wins. |

### Phase 7 — verification sweep

Run everything, from a clean checkout, and paste the output into the PR:

```
python3 scripts/validate.py                          # both backends
python3 -m pytest -q                                 # all suites
python3 scripts/render.py | jq -e .                  # Wiz tfvars, byte-identical to before
python3 scripts/mock_plan.py
python3 scripts/render_kyverno.py --check            # no drift
python3 scripts/render_kyverno.py --summary
python3 scripts/render_kyverno.py --diff-versions nonprod/wizn02
bash scripts/verify_manifests.sh                     # kubeconform, both CRD versions
bash scripts/debug_base_layers.sh --help
terraform -chdir=../../container-vulnerability-exemption.wiz/terraform fmt -check
```

`terraform validate` and anything touching a live registry or cluster stays out — the `wiz-v2`
provider is internal and there is no Docker daemon available.

---

## 6. Sequencing

Phase 0 first and **merged separately** — it is pure rename/move noise, and mixing it with
Phase 1–2 would bury the semantic changes in a 40-file diff. Phases 1–3 are one change (schema,
renderer and its tests are meaningless apart). Phase 4 is mechanical output. Phases 5–6 land
together, since the CI workflow and the READMEs describing it should not disagree even briefly.

---

## 7. Open questions and risks

**Q1 — repo boundary.** Are `.wiz` and `.kyverno` genuinely separate git repos, or directories
of one? It decides whether `render_kyverno.py --check` is a same-checkout diff or a cross-repo
PR bot, and it decides where "apply" happens for the Kyverno backend. *Assumed for now:*
separate repos, CI renders and pushes; `--check` works in both models.

**Q2 — Deployment / pod-controller exceptions (§3.3).** Unverified whether autogen rewrites a
`PolicyException`'s `matchConditions`. The shape-tolerant prefix is a belt-and-braces fix, but
POC 5.12 must be extended to confirm. **This is the highest-severity unknown**: if exceptions do
not fire for Deployments, every vendor workload is denied on day one.

**Q3 — multi-PEM `certs.value` (§3.7).** Blocks the add-new → re-sign → remove-old CA rotation
story on the Kyverno side. Wiz has it via `notary_v2`'s list. Confirm in the POC.

**Q4 — 1.19 is still rc.** Chart `3.9.0-rc.4` / app `v1.19.0-rc.4`. The 1.19 tree is
*rendered and validated* but should not be applied to anything that matters until GA. The
per-cluster version pin exists precisely so the answer to "are we ready" is a one-line PR.

**Q5 — F4 on 1.18.2.** Verification runs in the *mutating* webhook and is handed over in a pod
annotation a caller could forge if mutate is bypassed. Nothing in this plan mitigates it — it is
a property of the version. It is a reason not to run 1.18.2 in `Deny`, and it should be recorded
in the Kyverno README next to the enforcement mapping rather than discovered later.

**Q6 — exception blast radius.** `--enablePolicyException` defaults false (an exception applies
and does nothing), and `--exceptionNamespace` must be a single namespace or any namespace-admin
can exempt anything with unrestricted CEL. Both are cluster install config, outside these
manifests. The renderer emits a `README` note per cluster directory; the POC's
`guardrail-vpol.yaml` is the enforcement path and should be adopted, not just tested.

**Q7 — what none of this settles.** Kyverno does not scan for vulnerabilities. Even with per-entry
expiry, tickets and approvers (D2/D3 recover everything F5 gave back), a `PolicyException`
answers "may this image be admitted", not "do we accept this CVE" — you would still run a scanner
with its own ignore list. That, plus fan-out to ~200 etcds versus one tenant API, is ADR-0002
rationales 1 and 2, and this plan moves neither. The plan makes the bake-off *fair*; it does not
pre-empt it.
