# Implementation Plan — new_direction.md (review before build)

> ## ⚠ PARTLY SUPERSEDED by [`terraform-rework_PLAN.md`](terraform-rework_PLAN.md)
>
> **Still current:** the admission model this document exists to establish — signature-based
> compliance, NOTARY over cosign, no compliant allowlist, no compliance-bot, one ignore rule
> per exemption, enforcement per env.
>
> **No longer true**, everything in here about terraform topology and CI:
>
> | this document says | now |
> | --- | --- |
> | a `bootstrap/` module in its own state | no bootstrap; **one state per Wiz tenant** holds everything |
> | clusters read `validator_id` from bootstrap remote state (Q2) | plain in-state resource reference |
> | one apply = one cluster, `unikube/wiz-<tenant>/<env>-<cluster>.tfstate` | one apply = the whole tenant, `unikube/wiz-<tenant>.tfstate` |
> | golden `cst-container-vuln-default` + `golden.yaml` (Q7) | **deleted**, along with the informational scan step |
> | `compute_matrix.py` computes affected clusters | **deleted**; one job, no matrix |
> | env-global exemptions materialized per cluster with a `-global-` marker | **ONE shared rule per env**, `ignore-<env>-global-<name>` |
> | engine/schema pins per env or cluster | per **Wiz tenant**, in `exemptions/tenants.yaml` |
>
> The Q&A below is kept as the decision record for the signature model. Do not read its
> terraform sections as a description of the code.

**Nothing implemented yet.** Review, answer the inline questions, and I'll build from your
answers. This supersedes the compliant-allowlist parts of `tweak_PLAN.md`.

## The core idea (what changes)

Admit compliant self-built images by **signature verification**, not by an auto-merged
allowlist PR. The Wiz `image_integrity_validator` is configured with a signing method
(`COSIGN` or `NOTARY`); the unikube workflow signs compliant images; Wiz then admits them
because the signature verifies. No compliant PR, no `*.compliant.yaml`, no bot.

- **Self-built, compliant** → workflow signs → push → admitted by the validator. (no YAML)
- **Self-built, NOT compliant** → workflow clones the interface repo, checks the target
  cluster(s)' **already-merged** exemptions; if the image matches an exemption → push
  (admitted by that ignore rule); if not → **fail CI red** ("not compliant, no exemption —
  raise a PR").
- **Vendor / OSS** → always manual `exemption` (never built by unikube).

Consequences: per-cluster **vuln policy is removed** (only a single golden informational
scan policy remains); the **compliant/exemption file split, the sidecars, `add_compliant.py`,
the compliance-bot, and the auto-merge PR flow are all removed**; the schema collapses to a
single `exemptions` list where **each entry is its own ignore rule** with its own expiry.

---

## Cosign vs Notation (your evaluation ask)

For an **air-gapped, internal enterprise with CA + private key + signing certificate**
(keyless is out), the recommendation is **Notation (Notary Project v2)**:

- Notation is **built for enterprise X.509 PKI** — CA-issued certs, trust stores + trust
  policies, no dependency on Sigstore's public Fulcio/Rekor. It's the standard choice for
  air-gapped/internal-PKI environments.
- Key material lives behind a **plugin** to your HSM/KMS/Vault (Azure Key Vault, AWS Signer,
  HashiCorp Vault) — a good match for enterprise key custody.
- Signatures are stored as **OCI artifacts via the referrers API (ORAS)** — works fully
  offline against your own registry.
- Cosign *can* do key/cert signing offline (`--key`, `--tlog-upload=false`), but its happy
  path and ecosystem are **keyless/Sigstore**; using it purely with a CA cert is going
  against its grain (some tooling doesn't even support Fulcio-less X.509 cosign).

**Recommendation:** standardize on **Notation**, and set the Wiz validator to `NOTARY`.
I'll make the validator **method configurable** (a variable `validator_method = NOTARY|COSIGN`)
so it isn't hard-coded, but default to `NOTARY`. (Your current module sets *both* `COSIGN`
and `NOTARY` blocks — that's invalid since they're mutually exclusive; the config var fixes
that.)

---

## Proposed terraform architecture

**bootstrap/ (fleet-wide, own state, per Wiz tenant):**
- `cst-container-vuln-default` — the single informational scan policy (AUDIT), params from
  `golden.yaml`. Used by the unikube scan step. (already exists)
- **`cst-container-image-validator-default`** — ONE shared image-integrity validator holding
  the `NOTARY`/`COSIGN` cert config. (moved here — see Q2)

**terraform/ (per cluster, own state):**
- `cst-container-image-trust-<env>-<cluster>` — Image-Trust admission policy (per cluster,
  because exemptions are per-cluster). References the shared validator (read-only).
- **N ignore rules**, one per exemption entry (via `for_each`), each named + expirable:
  - `cst-ignore-<env>-<cluster>-<name>` for cluster-file exemptions
  - `cst-ignore-<env>-<cluster>-global-<name>` for env `global.yaml` exemptions (materialized
    per cluster). The trust policy lists all their ids.
- Per-cluster **vuln policy is deleted** (no `cst-container-vuln-<env>-<cluster>`, no
  `vuln_params` rendered per cluster).

Because each exemption is its **own** ignore rule, `operator` can be `equal` **or**
`starts_with` **or** `matches_regex` per entry with no mutual-exclusivity conflict (that was
only a problem when many operators shared one rule).

---

## New schema (much simpler — one file per cluster/env)

`<env>/<cluster>.yaml` and `<env>/global.yaml`:

```yaml
schema_version: "1.0.0"
container-vulnerability-exemption-tf_version: v1.0.0
admission:
  enforcement: AUDIT              # env default; cluster may override
exemptions:
  - name: k8s-pause               # short, unique-within-file slug (naming convention, Q4)
    image_value: "registry.k8s.io/pause"
    operator: starts_with         # equal | starts_with | matches_regex
    jiraTicketId: SEC-0001
    approved_by: platform-team
    expired_at: "2027-01-01"
```

Gone: `compliant_images`, `*.compliant.yaml`, `image_regex_pattern`, `pactId`. Each
`exemptions[]` element → one ignore rule (segregated, own `expired_at`).

---

## unikube workflow (new order — your "what's the best order?")

Recommended order per matrix target:

1. **Build** the image (needed to scan and to sign/inspect).
2. **Vuln scan — informational** against the golden `cst-container-vuln-default` (AUDIT;
   never blocks; captured for reporting).
3. **Compliance check**: static (every `FROM` is `container-soe.registry.domain/*`) +
   authoritative post-build (`docker inspect` base-layer **digests** + final base freshness
   ≤ 30 days; trust digests, not labels).
4. **Branch:**
   - **Compliant** → **Notation sign** (CA cert via plugin) → `docker push` → done. Admitted
     fleet-wide by the validator. Emit a note recording *why* it's compliant (base digest,
     freshness).
   - **Not compliant** → clone the interface repo, resolve the target cluster(s), check the
     image against those clusters' **merged, already-applied** exemptions:
     - **matches an exemption** → `docker push` (admitted by the ignore rule); log which
       exemption + why the image wasn't compliant.
     - **no exemption** → **fail** with a red message: not compliant, no exemption, raise a
       manual `exemption` PR.

Rationale: build first (scan + inspect both need the image); scan is cheap and informational
so run it early; compliance decides the branch; sign only compliant images (exempted images
are admitted by name, no signature needed).

---

## Changes by area

- **Schema:** rewrite `exemption.defs.json` (new `exemption` item: `name`, `image_value`,
  `operator` enum, `jiraTicketId`, `approved_by`, `expired_at`); `cluster.schema.json` /
  `global.schema.json` use `exemptions[]`. **Delete** `cluster.compliant.schema.json`,
  `global.compliant.schema.json`. `validate.py`: enum + regex-compiles-when-matches_regex +
  `expired_at` not past + unique `name` per file.
- **Scripts:** `common.py` — drop compliant/sidecar helpers; `merged_exemptions()` returns a
  list of `{name, operator, image_value, source: cluster|global}` (order + de-dupe by name).
  `render.py` tfvars → `cluster_name`, `env`, `admission_enforcement`, `exemptions` (list for
  `for_each`); drop `vuln_params`/`compliant_regex`. **Delete** `add_compliant.py`. `mock_plan.py`
  updated. `compute_matrix.py` — drop `*.compliant.yaml` handling; **golden change → bootstrap
  only** (clusters no longer use golden). Migrate all env files to the new `exemptions` schema.
- **Engine:** delete per-cluster vuln policy + `vuln_params`; module builds `for_each` ignore
  rules + trust policy referencing the shared validator; `policy_names` reflects the new set.
  bootstrap gains the shared validator; `validator_method` var (NOTARY default) with the cert
  config wired from a secret/var (stubbed). Fix the dual-method block.
- **Workflow / repo:** rewrite `unikube.yaml` (order above, Notation sign stub, exemption
  fallback, no PR). Update `self-built-image/`. Remove the compliant-PR + compliance-bot bits.
- **CODEOWNERS:** drop the `*.compliant.yaml` / `@org/compliance-bot` rule; exemptions are
  manual again (prod/preprod stricter).
- **Docs/tests:** update `project_summary.md`, READMEs, `image-signing-101.md` (add a
  Notation/air-gapped section); rework fixtures + tests; `compliance_check.py` tests stay.

---

## Open questions (answer inline)

**Q1 — Signing tool.** Standardize on **Notation** (validator `NOTARY`), method configurable
but defaulting to NOTARY? Or do you want COSIGN-with-key instead?

<user_response>
use NOTARY. everything NOTARY.
</user_response>

**Q2 — Validator: shared (bootstrap) vs per-cluster.** Recommendation: **shared in bootstrap**.
The signing cert is fleet-wide; rotating it **in place** on one validator keeps its id stable,
so **zero cluster re-applies** on rotation (vs. re-applying all ~200 clusters if per-cluster).
Cost: the cluster trust policy reads the validator id **read-only** from bootstrap state (a
small cross-state dependency, like the original golden design). Per-cluster keeps full
isolation but makes cert rotation a fleet-wide fan-out. Which do you want?

<user_response>
shared in bootstrap. Make sure to have full instructions and explain inner workings of how it reads bootstrap tfstate.
</user_response>

**Q3 — Fleet-wide compliance is a consequence, confirm intended.** A **signature is on the
image, not per-cluster** — so once a compliant image is signed, it's admitted on **every**
cluster whose trust policy uses the validator. You lose per-cluster control over self-built
images (only `exemptions` stay per-cluster). Is fleet-wide admission of signed images intended?
(If you need per-cluster control of self-built too, signature-based admission can't give it.)

<user_response>
fleet-wide admission of signed images intended for compliant images. so that is fine. Exemption is stricter and per cluster. so it works perfectly
</user_response>

**Q4 — Ignore-rule naming convention.** Propose Wiz names
`cst-ignore-<env>-<cluster>-<name>` (cluster) and `cst-ignore-<env>-<cluster>-global-<name>`
(global-derived), where `name` is a short unique slug per file (kebab-case, `^[a-z0-9-]+$`).
OK, or a different format/separator?
<user_response>
Remove `cst-`. just `ignore-<env>-<cluster>-<name>`
name should be max 10 character
</user_response>

**Q5 — `operator` spelling + Wiz mapping.** YAML enum `equal | starts_with | matches_regex`
(your wording). I'll map to the Wiz `image_name` fields `equals` / `starts_with` /
`matches_regex`. Keep `equal` (singular) in YAML, or use `equals` to match Wiz?
<user_response>
equals
</user_response>

**Q6 — Per-exemption expiry enforcement.** `expired_at` is per entry. Does
`wiz-v2_ignore_rule` support an expiry field so **Wiz** auto-expires? If yes, set it. If not,
I'll enforce in CI (validate fails on expired) — and optionally a scheduled job that opens a
cleanup PR. Which (and is there a provider expiry field)?

<user_response>
expired_at is Wiz field. no need to enforce on CI
</user_response>

**Q7 — Golden fan-out removal.** Since clusters no longer consume `vuln_params`, a `golden.yaml` change re-applies **bootstrap only** (not every cluster). Confirm we drop the
golden→all-clusters fan-out.

<user_response>
yes golden.yaml does NOT fan out anymore. the only fanout is image_validator change
</user_response>

**Q8 — Cert material source.** The validator needs the CA cert / chain (and Notation needs a
signing key via plugin). For the mock I'll stub these as bootstrap variables/secrets. Real
source — Vault? KMS? A specific secret name? (Interface only; values injected at apply.)

<user_response>
For now just assume local testing. so give script to:
- Generate CA, private key, csr, signing certificate.

CA.crt should be committed to git, since that will be trusted by any platform, unikube, pck. Any change in CA.crt should trigger re-apply of the bootstrap. 

For now, assume that signing.crt, and signing.key are fetchable from environment variable, so it won't be committed to git. so `- name: Sign (Notation) + push  [compliant]` unikube gha should access these variable and sign accordingly. Make this step into bash script so gha step can just run: `bash scripts/sign-image.sh <image_name>` for example.

</user_response>

**Q9 — unikube scope + push.** Confirm unikube is **self-built only** (vendor/OSS never call
it), and that the final `docker push` targets the tenant's own registry (unikube just
gates + signs + pushes). `target_clusters` matters only for the non-compliant→exemption
check (compliant images are fleet-wide, so it's informational there).

<user_response>
- vendor/OSS never calls
- `docker push` targets the tenant's own registry. tenant should supply credentials to push, either via SECRETS or OIDC. stub both
- `target_clusters` matters only for the non-compliant→exemption => CORRECT
</user_response>

## Pitfalls
- **Dual-method validator block is invalid** — `COSIGN` and `NOTARY` are mutually exclusive;
  the `validator_method` var will emit exactly one. (Your current code has both.)

<user_response>
I'm just stubbing it out for you to see. we decide to use `NOTARY`
</user_response>

- **Cross-state coupling returns** (only if Q2 = shared): cluster applies read the bootstrap
  validator id. Read-only, but bootstrap must be applied first.

<user_response>
is this a big issue? if yes then just go with duplicating validator for each cluster.
if not use shared
</user_response>

- **`for_each` on ignore rules** keys on `name` — a duplicate `name` (cluster vs cluster, or
  two globals) collides; validate enforces uniqueness, and global vs cluster are namespaced.

<user_response>
Yes validate uniqueness
</user_response>

- **Signature ≠ scope.** (See Q3.) Also: revoking compliance for one image = revoke/rotate
  its signature or add a deny — name-based ignore rules can't "un-admit" a signed image.

<user_response>
sure. However each signing certificate should have expiry, so when the signing certificate expire, that signed image is no longer admissible correct?
</user_response>

- **Provider support** for `matches_regex`/`starts_with`/`equals` per single ignore rule, and
  for a validator expiry field — confirm during the Wiz spike.

<user_response>
Yes expired_at is supported field. I added to wiz/container-vulnerability-exemption.tf/terraform/modules/cluster_policy_set/main.tf for your reference.
</user_response>

**EXTRA:** What about attestation? necessary?

---

# Round 2 — answers digested + final design lock (implementation-ready)

## Locked from your answers
- **NOTARY everywhere.** Validator method = `NOTARY`; drop the COSIGN block entirely (no
  `validator_method` var needed — it's just NOTARY). (Q1, dual-method pitfall)
- **Shared validator in bootstrap** — `container-image-validator-default`, holding the
  Notary CA cert. Cluster trust policies read its id read-only from bootstrap state
  (mechanics below). Cross-state read is **not** a big issue → shared. (Q2)
- **Fleet-wide admission of signed images is intended**; exemptions stay per-cluster. (Q3)
- **Ignore-rule name:** `ignore-<env>-<cluster>-<name>` (cluster) /
  `ignore-<env>-<cluster>-global-<name>` (global-derived). YAML `name` ≤ 10 chars,
  `^[a-z0-9-]+$`, unique per file (validated). (Q4, dup-name pitfall)
- **operator enum = `equals | starts_with | matches_regex`** → maps to the Wiz `image_name`
  field of the same name; each exemption is its own rule so exactly one is set. (Q5)
- **`expired_at` is a real Wiz `wiz-v2_ignore_rule` field** (you added it) → terraform sets
  it per rule; **no CI expiry enforcement**. validate keeps the date-format check only. (Q6)
- **`golden.yaml` no longer fans out to clusters** — bootstrap-only. (Q7)
- **Local cert testing:** I'll ship a `scripts/gen_signing_certs.sh` (openssl) that creates
  a root CA, a signing key + CSR, and a CA-issued signing certificate. (Q8)
- **unikube = self-built only**; `docker push` to the tenant registry with creds via
  **secrets OR OIDC (both stubbed)**; `target_clusters` only matters for the
  non-compliant→exemption path. (Q9)

## Q2 mechanics — how a cluster reads the bootstrap validator id (you asked to explain)

The validator is created once in `terraform/bootstrap` and its **id is written into the
bootstrap state file** (`unikube/wiz-<tenant>/_bootstrap.tfstate`) via an output:

```hcl
# bootstrap/  (writes the id into bootstrap state)
output "validator_id" { value = wiz-v2_image_integrity_validator.default.id }
```

Each cluster apply then **reads** that state read-only with a `terraform_remote_state` data
source and feeds the id into its trust policy — it never manages the validator:

```hcl
# terraform/  (per cluster)
data "terraform_remote_state" "bootstrap" {
  backend = "s3"
  config  = { bucket = var.state_bucket, key = "unikube/wiz-${var.wiz_env}/_bootstrap.tfstate", region = var.state_region }
}
# ... trust policy: image_integrity_validator_ids = [data.terraform_remote_state.bootstrap.outputs.validator_id]
```

Why it's safe / not a big deal: it's **read-only** (a cluster can't change or destroy the
validator), the coupling is one value (an id string), and the **id is stable across cert
rotation** — rotating the cert updates the validator *in place*, so the id in bootstrap
state doesn't change and **no cluster needs re-applying**. The only ordering rule:
**bootstrap must be applied before the first cluster apply** (documented + enforced by CI job
ordering). For offline/local single-cluster plans I'll add a `validator_id` override var
(so you can pass a stub and skip the remote-state read), mirroring the old golden pattern.

## Refinement on "the only fanout is image_validator change" (Q7)

With a **shared** validator this needs a small correction: because clusters reference the
validator by its (stable) id, a **cert rotation is bootstrap-only and does NOT require any
cluster re-apply** — the new cert is live for every cluster the moment bootstrap applies.
So after this change, **nothing fans out to all clusters**: `golden.yaml` → bootstrap only;
the validator cert → bootstrap only; `global.yaml` → that env's clusters; a cluster file →
that cluster. If you specifically want a **safety fan-out** (re-apply all clusters when the
validator changes, even though it's a no-op unless the validator id changes), say so and
I'll wire a `validator.yaml` → all-clusters trigger. **Default: bootstrap-only** (accurate).

<user_response>
It is true that cluster image trust reference validator by its (stable) id, so change in validator should also be refected. Nice no fanout needed. Thanks :)
</user_response>

## EXTRA — is attestation necessary? No (for the gate)

The **signature is the gate** now: Wiz's validator verifies the Notary signature, so an
attestation is **not required** for admission. Attestation (SLSA provenance / a compliance
predicate) would only add an **audit trail** of *why* an image was deemed compliant (base
digests, freshness). Recommendation: **skip attestation for now**; if you later want the
audit trail, emit a Notation-signed provenance statement as a non-blocking follow-up. Keeps
the pipeline lean.

## Signing-cert expiry → admissibility (your revocation question)

Yes — with the right config, **when the signing certificate expires, images signed by it
stop being admissible**, fleet-wide. Important nuance: this holds **only if you do NOT use
trusted timestamping** (RFC 3161). A timestamped signature stays valid *after* cert expiry
(it proves "signed while valid"), which is usually desirable but is the *opposite* of what
you want here. So to get "cert expiry = auto-revoke," either **don't timestamp** or set the
Notation **trust policy to require certificate validity at verification time**. Caveat: this
is **coarse** — it revokes *every* image signed by that cert at once. Revoking a single
image needs a deny rule or re-sign policy. I'll document this in the 101 + a short Notation
section.

<user_response>
Wait in that case use trusted timestamping is better to enforce freshness, like 1 year. The signing certificate can follow its own rotation lifecycle.
For image, once trusted timestamping, it should be good for that period of time. Correct?
</user_response>

## Build inventory (what I'll build)

- **Schema:** rewrite `exemption.defs.json` (exemption = `name` ≤10, `image_value`,
  `operator` enum, `jiraTicketId`, `approved_by`, `expired_at`); `cluster/global.schema.json`
  use `exemptions[]`. **Delete** the two `*.compliant.schema.json`. `validate.py`: enum,
  `name` length + uniqueness, regex-compiles-if-`matches_regex`, date format (no past check).
- **Scripts:** `common.py` `merged_exemptions()` (list of `{name, operator, image_value,
  scope}`; namespace global vs cluster; enforce unique names). `render.py` tfvars →
  `cluster_name, env, admission_enforcement, exemptions[]` (for `for_each`). **Delete**
  `add_compliant.py`; drop `vuln_params`/`compliant_regex`. `compute_matrix.py`: drop
  `*.compliant.yaml`; golden → bootstrap only. Migrate all env files to the new schema.
- **Engine:** delete per-cluster vuln policy; module = trust policy (referencing the shared
  validator id) + `for_each` ignore rules with `expired_at`; `policy_names` updated. bootstrap
  gains the shared NOTARY validator + `validator_id` output; root reads it via
  `terraform_remote_state` (+ `validator_id` override for local). `gen_signing_certs.sh`.
- **Workflow/repo:** rewrite `unikube.yaml` (build → informational scan → compliance →
  sign(NOTARY)+push OR exemption-check→push/fail; push creds secrets-or-OIDC stubbed).
  Update `self-built-image/`. Remove compliant-PR/compliance-bot.
- **CODEOWNERS:** drop the `*.compliant.yaml` bot rule; exemptions manual (prod/preprod stricter).
- **Docs/tests:** `project_summary.md`, READMEs, `image-signing-101.md` (+ Notation/air-gapped
  + cert-expiry-revocation section); rework fixtures/tests; keep `compliance_check.py` tests.
- **Verify:** validate + pytest + tf brace + yaml parse, all green.

## Status
**Implementation-ready.** One optional refinement left to your taste (the validator
safety-fan-out; default is bootstrap-only). Prompt me to build.

Sources for the signing evaluation:
- [Notary V2 and Cosign — Dan Lorenc](https://dlorenc.medium.com/notary-v2-and-cosign-b816658f044d)
- [Container Signing Tools Compared: Cosign vs Notation vs GPG](https://secure-pipelines.com/ci-cd-security/container-image-signing-tools-compared-cosign-notation-gpg/)
- [Sign Container Images with Notation and a CA-Issued Certificate (Microsoft Learn)](https://learn.microsoft.com/en-us/azure/container-registry/container-registry-tutorial-sign-trusted-ca)
