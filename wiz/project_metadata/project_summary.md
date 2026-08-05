# Project Summary — Container Vulnerability Exemption

The single entry point for understanding this project. Read this, then the two repo
READMEs it points to, and you know the system end to end:

- **[`container-vulnerability-exemption/unikube/README.md`](../container-vulnerability-exemption/unikube/README.md)** — the interface repo (unikube platform): exemption YAML schema, the local verify/plan commands, the scripts. (The repo root README just routes between platforms.)
- **[`container-vulnerability-exemption.tf/README.md`](../container-vulnerability-exemption.tf/README.md)** — the engine repo: module layout, the Wiz objects, state model, bootstrap, local plan.
- **[`image-signing-101.md`](image-signing-101.md)** — the signing / Notation / cert-expiry trust model.

## What this system does

It lets teams manage Wiz container-vulnerability **exemptions** and **admission** for the
unikube EKS fleet (200+ clusters) through reviewed YAML instead of clicking in Wiz.
Customers declare which images may be exempted on their cluster; CI validates and turns
that YAML into Wiz policies via Terraform. Blast radius is one cluster per change.

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

**How they connect:** the interface repo's `unikube/scripts/render.py` turns a cluster's
YAML (addressed as `<env>/<cluster>`, e.g. `dev/anp07`) into a `*.auto.tfvars.json`
contract; the `.github/actions/tf` composite action clones the engine at the version the
cluster pins and runs `terraform plan/apply/destroy` against that cluster's own state.
The engine is never edited by customers.

## Admission model — signature (compliant) + name (exemption)

Compliant self-built images are admitted by **signature verification**, not a YAML
allowlist. The unikube workflow **NOTATION-signs** compliant images; a single fleet-wide
Wiz `image_integrity_validator` (method `NOTARY`) verifies the signature, so a signed image
is admitted on **every** cluster. Exemptions (vendor/OSS or accepted-risk) remain per-cluster
and manual. Vuln scanning still runs in CI but is **informational** (a single golden AUDIT
policy). Trust-model detail (Notation, CA/PKI, cert-expiry revocation) is in
`image-signing-101.md`.

## Wiz objects

**bootstrap (fleet-wide, own state, per Wiz tenant):**
- `cst-container-vuln-default` — the one **informational** vuln scan policy (AUDIT), `vuln_params` from `golden.yaml`.
- `cst-container-image-validator-default` — the one **shared NOTARY validator**, holding the CA trust root (`notary_ca_certificate`, rendered from repo-root `trust/ca.crt`). Replacing the cert is a single bootstrap apply, id stable, **zero cluster re-applies**.

Those are bootstrap's only two inputs, and `render_bootstrap.py` emits both, so one
`-var-file` drives the apply. `notary_ca_certificate` has no terraform default and is
validated, so a forgotten value fails the apply instead of installing a placeholder that
would break admission tenant-wide.

**per cluster (own state):**
- `cst-container-image-trust-<env>-<cluster>` — Image-Trust admission policy; references the shared validator id (read read-only from bootstrap state).
- **N `wiz-v2_ignore_rule`** (one per exemption entry, via `for_each`):
  `ignore-<env>-<cluster>-<name>` (cluster file) / `ignore-<env>-<cluster>-global-<name>` (env global). Each has its own `operator` (`equals`/`starts_with`/`matches_regex`) and its own `expired_at` (Wiz auto-expires).

Because each exemption is its **own** rule, any operator is fine (the mutual-exclusivity of
`equals`/`starts_with` only bites when they share one rule).

## Exemption schema

`<env>/<cluster>.yaml` and `<env>/global.yaml` (manual, security-approved):

```yaml
schema_version: "1.0.0"
container-vulnerability-exemption-tf_version: v1.0.0
admission:
  enforcement: AUDIT              # env default; cluster may override
exemptions:
  - name: k8s-pause              # <=10 chars, unique per file -> ignore-rule name suffix
    image_value: "registry.k8s.io/pause"
    operator: starts_with        # equals | starts_with | matches_regex
    jiraTicketId: SEC-0001
    approved_by: platform-team
    expired_at: "2027-01-01"     # Wiz field; auto-expires the rule
```

There is **no** compliant YAML — compliant images carry a NOTARY signature instead.

## Key decisions

1. **Signature-based compliance, per-cluster exemptions.** Compliant self-built images are admitted fleet-wide by their NOTARY signature (the shared validator); exemptions are manual, per-cluster ignore rules. No compliant allowlist YAML, no compliance-bot, no auto-merge PR.
2. **NOTARY (Notation), not cosign.** Air-gapped + CA/X.509/private-key model → Notary Project v2 (Notation) is the fit; cosign leans keyless/Sigstore.
3. **Shared validator in bootstrap.** One fleet-wide validator holds the CA trust root; clusters read its id read-only from bootstrap state. Changing the cert = one bootstrap apply, stable id, zero cluster re-applies. Ordering: bootstrap applies before the first cluster. A `validator_id` override lets a single cluster plan offline.
4. **Single informational scan.** One golden `cst-container-vuln-default` (AUDIT) used by the CI scan step; **no per-cluster vuln policy**. `golden.yaml` change → **bootstrap only** (no cluster fan-out) — as with the trust root, see 11.
5. **Each exemption = its own ignore rule** (`for_each`), with its own operator + `expired_at`. `name` ≤ 10 chars, unique per file (validated); global exemptions are materialized per cluster with a `-global-` marker.
6. **Enforcement per env, overridable per cluster.** `admission.enforcement` (AUDIT/BLOCK) in each env's `global.yaml`, overridable per cluster.
7. **Version + schema pinning.** Engine version and `schema_version` pin per env in `global.yaml`, overridable per cluster; cluster pin wins.
8. **One apply = one cluster.** State key `unikube/wiz-<tenant>/<env>-<cluster>.tfstate`; matrix plans/applies only affected clusters in parallel.
9. **Promotion axis = Wiz tenant.** CD applies Wiz NONPROD → gated Wiz PROD, chosen by SA credentials.
10. **Per-platform layout + isolated tests.** Interface under `unikube/` (extensible to `pck/`); engine under `terraform/`; scripts address `<env>/<cluster>`; pytest runs on synthetic fixtures.
11. **Trust root in git, at the repo root** (`trust/ca.crt`) — not in `golden.yaml`, not in the engine repo, not in a secret store. A CA *certificate* is public; the CA *key* is the secret and stays in an HSM/KMS. What needs protecting is **write authority**, and git + CODEOWNERS gives that a reviewable PR trail a secret store does not (a Vault value can change with no diff and is invisible to `terraform plan` on a PR). Root-level because the validator is shared across platforms and both tenants. `golden.yaml` was rejected — its platform-only review bar is wrong for a fleet-wide trust anchor, and a `vuln_params` typo is harmless where a cert typo is a fleet-wide outage. The engine repo was rejected — cert rotation would become a code release and would bake one org's CA into a reusable module. A change here triggers **bootstrap only**, same as `golden.yaml`. **One CA serves both tenants**, so replacing it is a hard cutover with no overlap window. (Resolves Q8.)
12. **The image is one artifact, so `unikube.yaml` has no job matrix.** Build → scan → compliance → sign → push each run **once**; only the exemption check loops over `target_clusters`. A matrix would mean N identical builds and N concurrent pushes of the same tag. Compliant images ignore `target_clusters` entirely (the signature admits them fleet-wide); non-compliant images are pushed only if **every** listed target is covered.

## How a change flows

**Common mechanics (every change).** A PR touching `unikube/exemptions/**` or
`unikube/schemas/**` runs the `terraform` workflow: a `matrix` job validates the files
and computes the affected set (which clusters + whether a bootstrap input — `golden.yaml`
or `trust/ca.crt` — changed). On the
**PR** it runs `terraform plan` for each affected cluster (Wiz NONPROD, then gated Wiz
PROD, plan-only) and posts the `env|cluster|ADD|CHANGE|DESTROY|Job link` bot comment. On
**merge to main** it runs `plan`+`apply`, Wiz NONPROD first, then a gated approval, then
Wiz PROD. Each cluster runs in parallel against its **own** state
(`unikube/wiz-<tenant>/<env>-<cluster>.tfstate`), and the engine is cloned at the version
that cluster resolves to (**cluster pin trumps env pin**). Blast radius is one cluster.

The concrete use cases:

**1. Tenant admits a self-built image (in their own repo).**
Call the reusable `unikube.yaml` (`image`, `tag`, `target_clusters`). **Once** (not per
target — there is one image): build → informational Wiz scan (golden AUDIT) → compliance
check (every `FROM` on `container-soe.registry.domain/*` + post-build base-layer **digests**
+ freshness ≤ 30 days; digests, not labels). Then branch:

- **Compliant** → push, then `scripts/sign-image.sh` signs the pushed **digest**
  (`notation sign`; leaf cert + key from CI env or an HSM/KMS plugin). Admitted fleet-wide by
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
→ merge. Matrix = that one cluster (`apply`); the affected ignore rule(s) are created/updated
(each entry is its own rule with its own `expired_at`).

**3. Env-wide exemption / enforcement / pin via `global.yaml`.**
Edit `unikube/exemptions/<env>/global.yaml` → PR → merge. Matrix = **every cluster in that
env** (`apply`). Env-wide exemptions are materialized on each cluster (`-global-` name); an
enforcement change flips each cluster's Image-Trust policy (unless overridden).

**4. Onboard / offboard a cluster.**
Add `<env>/<cluster>.yaml` → that cluster `apply` (creates the trust policy + its ignore
rules + fresh state). Delete it → that cluster `destroy` (+ the `tf` action removes the
orphan S3 state object).

**5. Roll out a new engine/schema version (canary → env → promote envs).**
Cut engine `v3.0.0` + bump the schema. Canary one cluster by pinning
`container-vulnerability-exemption-tf_version: v3.0.0` on its file (cluster pin trumps env);
then bump the env `global.yaml` pin to roll the env; then repeat env-by-env, dev → prod.

**6. Change the golden vuln baseline.**
Edit `unikube/exemptions/golden.yaml` (`vuln_params`) → PR → merge. Matrix = **bootstrap
only** (re-applies the informational `cst-container-vuln-default`). Clusters don't consume it,
so **no cluster fan-out**.

**7. Rotate the signing leaf (routine, ~90 days).**
Re-issue `signing.crt`/`signing.key` from the same CA and update the CI secrets (or the KMS
key). **No terraform, no PR in either repo** — `trust/ca.crt` is unchanged, so the validator
is untouched. Because signatures are **not** timestamped, images signed by an **expired**
leaf stop being admissible — a coarse, fleet-wide revocation, which is why the leaf is kept
short-lived. `sign-image.sh` refuses to sign with an expired cert and warns inside 7 days.
(See `image-signing-101.md`.)

**8. Replace the CA trust root (rare: compromise or PKI migration).**
Edit `trust/ca.crt` → PR → **security approval** → merge. Matrix = **bootstrap only**
(the shared validator updates in place); the id is stable → **no cluster re-applies**, and
the new trust root is live fleet-wide at once. ⚠ **Hard cutover**: the validator holds one
trust anchor and one CA serves both tenants, so every image signed by the old CA becomes
unadmissible the moment the apply lands. Plan it as a fleet-wide event and re-sign first.
(See `container-vulnerability-exemption/trust/README.md`.)

## Ownership (CODEOWNERS)

Security (`@org/security-leads`), platform (`@org/unikube-platform`), and customer teams who
co-own their cluster file. `CODEOWNERS`, `trust/`, and all `preprod/` + `prod/` changes
require security approval — `trust/` because a swapped CA cert would admit anything on every
cluster in both tenants, which is a strictly larger blast radius than any single exemption.
**There is no compliance-bot** — compliant images are admitted by signature, not by an
auto-merged file. `pck/` is out of scope. See `container-vulnerability-exemption/CODEOWNERS`.

## Repository-specific detail

- Exemption YAML shape, `operator` semantics, local verify + `local_tf.sh` →
  [`container-vulnerability-exemption/unikube/README.md`](../container-vulnerability-exemption/unikube/README.md).
- Engine module/bootstrap (shared validator + remote-state read), full bootstrap run,
  provider notes → [`container-vulnerability-exemption.tf/README.md`](../container-vulnerability-exemption.tf/README.md).
- Signing / Notation / cert-expiry trust model → [`image-signing-101.md`](image-signing-101.md).
- Trust-root custody, what is/isn't in git, CA-rotation cutover →
  [`container-vulnerability-exemption/trust/README.md`](../container-vulnerability-exemption/trust/README.md).

## Follow-ups (out of scope / stubbed)

- **Signing is real but unexercised.** `scripts/sign-image.sh` invokes `notation` for real
  (file key, or an HSM/KMS plugin via `NOTATION_PLUGIN`), and validates/expiry-checks the
  leaf; it has never run against a live registry or a real Notation install in CI. The
  runner still needs `notation` installed and registry credentials. `docker inspect`
  base-digest/freshness verification and the registry push (secrets or OIDC) remain stubbed.
- **Leaf custody.** `trust/ca.crt` is settled (in git, security-owned). Still open: where the
  **signing leaf** lives in CI — plain GitHub secrets vs. an HSM/KMS plugin — and who runs
  the 90-day re-issue.
- **Real state backend.** Wire an actual S3 bucket + DynamoDB lock and the bootstrap/import
  path for ~200 clusters × 2 tenants.
- **CA rotation has no overlap window.** `notary_v2.certificate` holds a single trust anchor.
  If an overlap is ever needed, a concatenated PEM bundle (old + new) is the usual mechanism
  — **unverified against the Wiz provider**; confirm during the spike.
- **Provider schema.** Confirm real `wiz-v2` attribute names during the Wiz spike (validator
  `notary_v2`, ignore-rule `expired_at`, `image_name.matches_regex`); the module is built
  against the blackbox reference and not yet run through `terraform validate` with the live
  provider. `.github/workflows/wiz-scan.yaml` is an obsolete parked placeholder.
