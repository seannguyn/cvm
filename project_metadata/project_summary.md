# Project Summary — Container Vulnerability Exemption

The single entry point for understanding this project. Read this, then the two repo
READMEs it points to, and you know the system end to end:

- **[`container-vulnerability-exemption/unikube/README.md`](../container-vulnerability-exemption/unikube/README.md)** — the interface repo (unikube platform): exemption YAML schema, the local verify/plan commands, the scripts. (The repo root README just routes between platforms.)
- **[`container-vulnerability-exemption.tf/README.md`](../container-vulnerability-exemption.tf/README.md)** — the engine repo: module layout, the Wiz objects, state model, local plan.
- **[`terraform-rework_PLAN.md`](terraform-rework_PLAN.md)** — why there is one state per tenant, why env-global rules are shared, and what was removed to get there.
- **[`image-signing-101.md`](image-signing-101.md)** — the signing / Notation / cert-expiry trust model.
- **[`notation-signing.md`](notation-signing.md)** — Notation operational reference: the three clocks (cert validity / TSA / signature expiry), what verification enforces at each level, why the PKI has three tiers, and which rotations have deadlines.

## What this system does

It lets teams manage Wiz container-vulnerability **exemptions** and **admission** for the
unikube EKS fleet (200+ clusters) through reviewed YAML instead of clicking in Wiz.
Customers declare which images may be exempted on their cluster; CI validates and turns
that YAML into Wiz policies via Terraform. One apply covers a whole Wiz tenant.

## The two repos

| Repo | Role | Who edits it |
|------|------|--------------|
| `container-vulnerability-exemption` | YAML **interface** — schema-validated config, CI, CODEOWNERS | Customers + Platform + Security |
| `container-vulnerability-exemption.tf` | Terraform **engine** — creates the Wiz resources, git-tag versioned | Platform / Security |

Each platform is scoped under its own directory in the interface repo
(`unikube/{exemptions,schemas,scripts,tests}`; `pck/` is a stub for a future team), and
all engine Terraform lives under `container-vulnerability-exemption.tf/terraform/`.

One thing deliberately sits at the interface repo's **root** rather than under a platform:
`trust/ca.crt`, the Notation CA certificate the shared validator verifies signatures
against. The validator is per Wiz tenant and shared by every platform, so a
platform-scoped path would misstate its blast radius. It carries the repo's strictest
CODEOWNERS rule. See `container-vulnerability-exemption/trust/README.md`.

**How they connect:** the interface repo's `unikube/scripts/render.py` turns the whole
exemptions tree, plus the trust anchors, into a single `fleet.auto.tfvars.json` contract; the
`.github/actions/tf` composite action clones the engine at the version that **Wiz tenant**
pins and runs `terraform plan/apply` against that tenant's single state. The engine is never
edited by customers.

## Admission model — signature (compliant) + name (exemption)

Compliant self-built images are admitted by **signature verification**, not a YAML
allowlist. The unikube workflow **NOTATION-signs** compliant images; a single fleet-wide
Wiz `image_integrity_validator` (method `NOTARY`) verifies the signature, so a signed image
is admitted on **every** cluster. Exemptions (vendor/OSS or accepted-risk) remain per-cluster
and manual, at two scopes (env-shared and cluster-own). There is **no vuln scan policy** —
it was informational and its result was ignored either way. Trust-model detail (Notation,
CA/PKI, cert-expiry revocation) is in `image-signing-101.md`.

## Wiz objects

All of it in **one state per Wiz tenant** (`unikube/wiz-<tenant>.tfstate`):

- `cst-container-image-validator-default` — the one **shared NOTARY validator**, holding the CA trust roots (`notary_ca_certificates`, a list, rendered from every repo-root `trust/*.crt`). It has no terraform default and is validated, so a forgotten value fails the apply instead of installing a placeholder that would break admission tenant-wide.
- `cst-container-image-trust-<env>-<cluster>` — one Image-Trust admission policy per cluster, referencing the validator directly (same state, no remote-state read).
- **`wiz-v2_ignore_rule`, at two scopes, AGGREGATED:**
  - `ignore-<env>-global` — ONE per env that has `global.yaml` exemptions, referenced by every cluster in that env.
  - `ignore-<env>-<cluster>` — ONE per cluster that has its own.

  Wiz caps ignore rules per tenant, so all of a scope's exemptions become one rule's
  `starts_with` list. A cluster references **at most two** rules however many exemptions it
  has; a scope with none gets no rule. Fleet total ≈ `#envs + #clusters`, not `#entries`.

The trade, accepted deliberately: a rule carries ONE operator and ONE expiry, so per-entry
`operator` and `expired_at` are gone. Matching is always `starts_with` against a literal
prefix — which is the operator that still does useful work when many exemptions share a rule,
since one prefix covers every tag. **Nothing auto-expires:** an exemption lives until its
line is deleted from the YAML.

## Exemption schema

`<env>/<cluster>.yaml` and `<env>/global.yaml` (manual, security-approved):

```yaml
admission:
  enforcement: AUDIT              # env default; cluster may override
exemptions:                       # every entry -> one more prefix in this scope's ONE rule
  - name: k8s-pause              # <=10 chars, unique per file; a review label only
    image_value: "registry.k8s.io/pause"   # literal PREFIX (starts_with); no regex, no globs
    jiraTicketId: SEC-0001
    approved_by: platform-team
```

There is **no** compliant YAML — compliant images carry a NOTARY signature instead. Version
pins are not in these files: engine and schema versions pin per **Wiz tenant** in
`unikube/exemptions/tenants.yaml`.

## Key decisions

1. **Signature-based compliance, manual exemptions.** Compliant self-built images are admitted fleet-wide by their NOTARY signature (the shared validator); exemptions are manual ignore rules, env-shared or cluster-own. No compliant allowlist YAML, no compliance-bot, no auto-merge PR.
2. **NOTARY (Notation), not cosign.** Air-gapped + CA/X.509/private-key model → Notary Project v2 (Notation) is the fit; cosign leans keyless/Sigstore.
3. **One state per Wiz tenant; no bootstrap.** The validator, every trust policy and every ignore rule share one state (`unikube/wiz-<tenant>.tfstate`). Both of a trust policy's references are in-state, so there is no `terraform_remote_state`, no `validator_id` override and no ordering constraint — and, crucially, a rule and the policies pointing at it are co-located, which is what makes a *shared* env rule expressible at all.
4. **No vuln scan policy at all.** The golden `cst-container-vuln-default` was AUDIT-only and its verdict was ignored on both branches, so it and `golden.yaml` are deleted along with the scan step in `unikube.yaml`.
5. **Exemptions are AGGREGATED into two rules per cluster**, because Wiz caps ignore rules per tenant: `ignore-<env>-global` (shared by the env) and `ignore-<env>-<cluster>`. An entry is an item in a rule's `starts_with` list, not a Wiz object, so adding one grows a list. Consequences: matching is prefix-only, and there is no `expired_at` anywhere — an exemption lives until its line is deleted. `name` ≤ 10 chars, unique per file, and is now a review label rather than part of any object name.
6. **Enforcement per env, overridable per cluster.** `admission.enforcement` (AUDIT/BLOCK) in each env's `global.yaml`, overridable per cluster.
7. **Version + schema pinning is per Wiz tenant** (`unikube/exemptions/tenants.yaml`). One apply covers a tenant, so one job can clone exactly one engine tag — a per-cluster or per-env pin had nowhere to be honoured. Bump nonprod → verify → bump prod *is* the rollout.
8. **One apply = the whole fleet for one tenant.** No cluster matrix; a change anywhere under `exemptions/**` or `trust/**` produces one plan per tenant. Deleting a cluster file is an ordinary destroy in that plan. The trade is blast radius: an apply touches every cluster in the tenant, and the single lock serializes concurrent PRs.
9. **Promotion axis = Wiz tenant.** CD applies Wiz NONPROD → gated Wiz PROD, chosen by SA credentials.
10. **Per-platform layout + isolated tests.** Interface under `unikube/` (extensible to `pck/`); engine under `terraform/`; scripts address `<env>/<cluster>`; pytest runs on synthetic fixtures.
11. **Trust root in git, at the repo root** (`trust/*.crt`) — not in the engine repo, not in a secret store. A CA *certificate* is public; the CA *key* is the secret and stays in an HSM/KMS. What needs protecting is **write authority**, and git + CODEOWNERS gives that a reviewable PR trail a secret store does not (a Vault value can change with no diff and is invisible to `terraform plan` on a PR). Root-level because the validator is shared across platforms and both tenants. The engine repo was rejected — cert rotation would become a code release and would bake one org's CA into a reusable module. A change here triggers the ordinary plan/apply (`trust/**` is in the CI path filter, deliberately: without it a reviewed CA could merge uninstalled). `notary_v2` takes a **list** of anchors, so rotation can be add-new → re-sign → remove-old with both roots trusted in between. (Resolves Q8.)
12. **The image is one artifact, so `unikube.yaml` has no job matrix.** Build → compliance → push → sign each run **once**; only the exemption check loops over `target_clusters`. A matrix would mean N identical builds and N concurrent pushes of the same tag. Compliant images ignore `target_clusters` entirely (the signature admits them fleet-wide); non-compliant images are pushed only if **every** listed target is covered.

## How a change flows

**Common mechanics (every change).** A PR touching `unikube/exemptions/**`,
`unikube/schemas/**` or `trust/**` runs the `terraform` workflow: a `validate` job runs
`validate.py` and the unit tests, then **one terraform job per Wiz tenant**. On the **PR**
both run `terraform plan` (NONPROD, then PROD) and the `comment` job posts real
`tenant|ADD|CHANGE|DESTROY` counts read from the uploaded plan JSON. On **merge to main**
they run `plan`+`apply`, Wiz NONPROD first, then a gated approval, then Wiz PROD. Each
tenant applies against its single state (`unikube/wiz-<tenant>.tfstate`), with the engine
cloned at that tenant's pinned tag. Blast radius is the tenant.

The concrete use cases:

**1. Tenant admits a self-built image (in their own repo).**
Call the reusable `unikube.yaml` (`image`, `tag`, `target_clusters`). **Once** (not per
target — there is one image): build → compliance check — one call to `compliance_check.py`, which owns every rule and runs `docker inspect`
itself (every `FROM` on `container-soe.registry.domain/*` + post-build base-layer **digests**
+ freshness ≤ 30 days; digests, not labels). Then branch:

- **Compliant** → push, then `scripts/sign-image.sh` signs the pushed **digest**
  (`notation sign`; leaf cert chain + key from CI env). Admitted fleet-wide by
  the shared NOTARY validator; no PR, no YAML, and `target_clusters` is not consulted at all.
- **Not compliant** → `check_exemption.py` runs for **every** entry in `target_clusters`
  against the already-merged `exemptions`, **before** any registry contact. All covered →
  push once, unsigned. Any target uncovered → every uncovered cluster is reported and the run
  **fails red** ("not compliant, no exemption — raise a PR"), with nothing pushed.
  All-or-nothing: one tag can't be admissible on some listed clusters and rejected on others.

**Push precedes sign** because a Notation signature is an OCI artifact stored in the registry
as a referrer to the image manifest — there is nothing to attach it to until the image is
there. So "pushed" never implies "admissible": an unsigned image is inert until the signing
step lands, and a failed signature fails the job red.

Vendor/OSS images never call this.

**2. Add/modify a manual exemption on one cluster.**
Edit `unikube/exemptions/<env>/<cluster>.yaml` (`exemptions[]`) → PR → **security approval**
→ merge. The plan shows an in-place update to that cluster's single `ignore-<env>-<cluster>`
rule — one more prefix in its `starts_with` list; nothing else in the tenant moves. If the
cluster had no exemptions before, the rule is created and attached.

**3. Env-wide exemption / enforcement via `global.yaml`.**
Edit `unikube/exemptions/<env>/global.yaml` → PR → merge. An exemption change touches the
**one** shared `ignore-<env>-global` rule — every cluster in the env already references it,
so no cluster object changes. An enforcement change flips each cluster's
Image-Trust policy in that env (unless overridden).

**4. Onboard / offboard a cluster.**
Add `<env>/<cluster>.yaml` → the plan creates its trust policy and its own ignore rules, and
wires in the env's shared rules. Delete it → the plan **destroys** them. No destroy mode, no
state object to clean up — but also no separate gate, so read the DESTROY count in the PR
comment.

**5. Roll out a new engine/schema version.**
Cut engine `v3.0.0`, bump `nonprod` in `unikube/exemptions/tenants.yaml` → PR → merge → the
nonprod apply runs the new engine. Verify in the Wiz nonprod tenant, then bump `prod` in a
follow-up PR. There is no per-cluster canary: one apply covers the tenant, so the tenant is
the smallest unit a version can be rolled to.

**6. Rotate the signing leaf (routine, ~365 days).**
Re-issue `signing.crt`/`signing.key` from the same CA and update the CI secrets (or the KMS
key). **No terraform, no PR in either repo** — `trust/ca.crt` is unchanged, so the validator
is untouched. Because signatures are **not** timestamped, images signed by an **expired**
leaf stop being admissible — a coarse, fleet-wide revocation, which is why the leaf is kept
short-lived. `sign-image.sh` refuses to sign with an expired cert and warns inside 7 days.
(See `image-signing-101.md`.)

**7. Replace the CA trust root (rare: compromise or PKI migration).**
Edit `trust/` → PR → **security approval** → merge. The plan shows a single in-place update
to the shared validator; its id is stable, so no trust policy changes and the new root is
live fleet-wide at once. ⚠ Do this as **add-new → re-sign → remove-old**, not a swap:
`notary_v2` takes a list, so both roots can be trusted in between. Replacing the only anchor
in one apply makes every image signed by the old CA unadmissible the moment it lands.
(See `container-vulnerability-exemption/trust/README.md`.)

## Ownership (CODEOWNERS)

Security (`@org/security-leads`), platform (`@org/unikube-platform`), and customer teams who
co-own their cluster file. `CODEOWNERS`, `trust/`, and all `preprod/` + `prod/` changes
require security approval — `trust/` because a swapped CA cert would admit anything on every
cluster in both tenants, which is a strictly larger blast radius than any single exemption.
**There is no compliance-bot** — compliant images are admitted by signature, not by an
auto-merged file. `pck/` is out of scope. See `container-vulnerability-exemption/CODEOWNERS`.

## Repository-specific detail

- Exemption YAML shape, prefix-matching semantics, local verify + `local_tf.sh` →
  [`container-vulnerability-exemption/unikube/README.md`](../container-vulnerability-exemption/unikube/README.md).
- Engine layout, the four resources, the tenant state model, provider notes →
  [`container-vulnerability-exemption.tf/README.md`](../container-vulnerability-exemption.tf/README.md).
- Signing / Notation / cert-expiry trust model → [`image-signing-101.md`](image-signing-101.md).
- Notation operational reference — what verification checks, PKI topology, rotation deadlines,
  key-compromise blast radius, Wiz spike questions → [`notation-signing.md`](notation-signing.md).
- Trust-root custody, what is/isn't in git, CA-rotation cutover →
  [`container-vulnerability-exemption/trust/README.md`](../container-vulnerability-exemption/trust/README.md).

## Follow-ups (out of scope / stubbed)

- **Signing is real but unexercised.** `scripts/sign-image.sh` invokes `notation` for real
  (file keys only — HSM/KMS plugin custody is a PKI-team follow-up), and validates/expiry-checks the
  leaf; it has never run against a live registry or a real Notation install in CI. The
  runner still needs `notation` installed and registry credentials. `docker inspect`
  base-digest/freshness verification and the registry push (secrets or OIDC) remain stubbed.
- **Leaf custody.** `trust/ca.crt` is settled (in git, security-owned). Still open: where the
  **signing leaf** lives in CI — plain GitHub secrets vs. an HSM/KMS plugin — and who runs
  the annual re-issue.
- **Real state backend.** Wire an actual S3 bucket + DynamoDB lock for the 2 tenant states.
  At ~200 clusters in one state, watch plan times and the lock-contention cost of serializing
  concurrent PRs — that is the known trade of the single-state design.
- **⚠ Shared ignore rules are unverified against the provider.** The design assumes the same
  `wiz-v2_ignore_rule` id can appear in the `ignore_rules` list of **multiple**
  `wiz-v2_cicd_scan_policy` resources. It is a settable list of ids, so this is likely, but
  the provider is blackbox. **Confirm before the first real apply.** If it rejects sharing,
  the fallback is per-cluster copies of the env rules and only the state consolidation lands.
- **⚠ The ignore-rule cap itself is not encoded anywhere.** The design aggregates to stay
  under it, but nothing fails if the fleet approaches it — the `ignore_rule_count` output is
  the only signal. Once the real limit is known, assert it.
- **Provider schema.** Confirm real `wiz-v2` attribute names during the Wiz spike (validator
  `notary_v2`, `image_name.starts_with` accepting a multi-element list); the module is built
  against the blackbox reference and has never been run through `terraform validate` with the
  live provider.
