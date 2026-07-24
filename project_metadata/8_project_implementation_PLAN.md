# Implementation Plan — Container Vulnerability Exemption

Plan for building out the two-repo system described in `8_project_implementation_0.md`.

## Source of truth

`8_project_implementation_0.md` + `container-vulnerability-exemption-tf/terraform/wiz-policies.tf` are **authoritative**. The existing `README.md`, workflows (`ci/cd/unikube.yaml`), and phase 4–7 metadata describe an *earlier, diverged* design and will be rewritten/replaced to match. Concretely, the consolidated model:

- **Naming:** `cst-container-vuln-*` and `cst-container-image-trust-*` (not `container-scan-*` / `container-admission-*`).
- **Folder:** `exemptions/unikube/<ENV>/<CLUSTER>.yaml` (not `exemptions_build/` + `exemptions_deploy/`).
- **Policy set:** 5 objects per cluster — a Vulnerability scan policy + its ignore rule, an image-integrity validator, an Image-Trust policy + its ignore rule. **No separate secrets/malware policies** (dropped from the older design).
- **Two exemption types per cluster:** *self-built* (CICD, maps to the Vulnerability ignore rule) and *vendor/OSS* (external, maps to the Image-Trust ignore rule).

Anything in the older artifacts contradicting the above is treated as stale.

## Clarifying questions

**Resolved (this session):**

1. Source of truth → goal doc wins; rewrite divergent README/workflows/metadata.
2. Scope → full scaffold of **both** repos, end-to-end runnable as a mock (no live Wiz tenant needed).

**Still open — proceeding with the stated assumption, flag if wrong:**

1. **Cluster YAML schema.** Left to me ("figure out the schemas that make most sense"). Proposed shape below — needs a thumbs-up before it hardens, since scripts + render + TF variables all bind to it.
2. **`wiz-policies.tf` internal linkage bug (line 88).** Object #4 (Image-Trust policy) sets `ignore_rules = [wiz-v2_ignore_rule.cst-container-vuln-ignore-CLUSTER_NAME.id]` — the *Vulnerability* ignore rule — while object #5 (`cst-container-image-trust-ignore-CLUSTER_NAME`) is defined but never referenced. Looks like it should point at #5. Assuming this is a bug to fix; confirm, since the doc calls the file "valid and working."

<user_response> 
  Yes it is a bug. Fix it.
</user_response> 

3. **Golden default state ownership.** `cst-container-vuln-default` is a single fleet-wide object, but state is sharded one-file-per-cluster (`ENVIRONMENT-CLUSTER_NAME`). Plan is to put the golden default in a **separate bootstrap state** and have per-cluster policies reference it — not manage it inside each cluster's state. Confirm.

<user_response> 
  Yes `cst-container-vuln-default` is a special case, and require it's own statefile.
  cluster state file should only logically reference this configuration.
</user_response> 

4. **Engine version pinning.** Cluster files already carry `container-vulnerability-exemption-tf_version` (anp07=v1.0.0, anp02/apr01=v2.0.0), i.e. per-cluster pinning; but the existing `action.yaml` reads a single global `version.yaml`. Plan is to honor the **per-cluster pin** and drop global `version.yaml`. Confirm.

<user_response> 
  Drop global `version.yaml`
  per cluster pinning or environment pinning, e.g. ENVIRONMENT/global.yaml is preferrable as you can test per cluster or environment
</user_response> 

5. **Enforcement source.** `global.yaml` currently holds `admission.enforcement: AUDIT` (env-wide). Assuming enforcement is set per-env in `global.yaml` and applied to every cluster's Image-Trust policy in that env, overridable per cluster. Confirm.

<user_response> 
  Correct. `admission.enforcement: AUDIT` is set per env level, but can be overriden per cluster level.
</user_response> 

## Target end state

```
container-vulnerability-exemption/                # interface repo (customer-facing)
  exemptions/unikube/<env>/<CLUSTER>.yaml         # self_built + vendor exemptions
  exemptions/unikube/<env>/global.yaml            # env enforcement + env-wide vendor allowlist
  exemptions/pck/                                 # out of scope, left as-is
  schemas/cluster.schema.json                     # JSON Schema for cluster + global files
  scripts/  validate.py compute_matrix.py render.py mock_plan.py common.py
  CODEOWNERS                                      # 3 actors, prod stricter
  .github/workflows/  terraform.yaml wiz-scan.yaml unikube.yaml
  .github/actions/tf/action.yaml                  # render + per-cluster plan/apply
container-vulnerability-exemption-tf/
  terraform/
    wiz-policies.tf                               # existing template (source material)
    modules/cluster_policy_set/                   # parametrised 5-object set
    bootstrap/                                    # golden cst-container-vuln-default (fleet-wide)
    main.tf variables.tf providers.tf versions.tf outputs.tf
    examples/anp07.auto.tfvars.json
```

## Proposed cluster YAML schema

`exemptions/unikube/dev/anp07.yaml`:

```yaml
schema_version: "1.0.0"
container-vulnerability-exemption-tf_version: v2.0.0

# self-built images → go through CICD → Vulnerability ignore rule (name_v2)
# these images are still scanned + tagged (wiz scan / wiz tag)
self_built:
  - value: "ecr/tenant_Y_image:1.0.0"
    operator: equals            # equals (FQIN) | starts_with
    ticket: JIRA-1234
    system_x_id: SYS-abc
    approved_by: security-team
    expiry: "2026-12-31"

# vendor / OSS images → built externally → Image-Trust ignore rule (image_name)
# allowed by name past the trust check, no scan
vendor_or_oss:
  - value: "registry.k8s.io/pause"
    operator: starts_with
    ticket: JIRA-5678
    system_x_id: SYS-def
    approved_by: platform-team
    expiry: "2027-06-30"
```

`exemptions/unikube/dev/global.yaml`:

```yaml
schema_version: "1.0.0"
admission:
  enforcement: AUDIT          # env-wide default for every cluster's Image-Trust policy
vendor:                       # optional env-wide vendor allowlist, applied to all clusters
  - value: "public.ecr.aws/"
    match: starts_with
    ticket: JIRA-0001
    approved_by: platform-team
    expiry: "2027-01-01"
```

`self_built.value` + `match` populate `name_v2.equals/starts_with` on the Vulnerability ignore rule; `vendor.value` + `match` populate `image_name.equals/starts_with` on the Image-Trust ignore rule (both are the fields marked `# EDITABLE via customer facing repos`). Business fields (ticket, system_x_id, approved_by, expiry) are validated but do not reach Wiz.

## Work plan

**1. Interface schema + validation.** Author `schemas/cluster.schema.json`; write `scripts/validate.py` (schema conformance, expiry-not-past, unique values, env/global consistency). Backfill the placeholder cluster files (anp07, anp02, apr01) and `global.yaml` files with the real schema so the repo validates green.

**2. Matrix computation.** `scripts/compute_matrix.py` reads a git diff file list and emits the affected-cluster JSON: a changed `<ENV>/<CLUSTER>.yaml` → that cluster; a changed `<ENV>/global.yaml` → every cluster in that env; a deleted cluster file → that cluster flagged for destroy. Output feeds the GH Actions matrix.

**3. Render.** `scripts/render.py --cluster <name>` merges the cluster file + its env `global.yaml` and emits `<CLUSTER>.auto.tfvars.json` (cluster_name, self_built list, vendor list incl. env-wide, enforcement, engine version). Deterministic; no Wiz calls.

**4. Terraform engine.** Refactor `wiz-policies.tf` into `modules/cluster_policy_set` parametrised by the tfvars contract (fixing the line-88 linkage). `main.tf` instantiates the module once per apply. `bootstrap/` manages the fleet-wide golden `cst-container-vuln-default` in its own state; per-cluster `cst-container-vuln-<cluster>` derives from it. Backend = S3 with key `unikube/<wiz-env>/<CLUSTER>.tfstate` (+ DynamoDB lock). Add `examples/anp07.auto.tfvars.json` and `mock_plan.py` so it runs without a live tenant.

**5. Terraform workflow** (`terraform.yaml`, replaces ci.yaml + cd.yaml). One workflow: on PR → compute matrix → parallel `terraform plan` per changed cluster (Wiz NONPROD then PROD, plan-only); on merge to main → `plan` + `apply`, NONPROD before a gated PROD. Handle create/modify vs delete (destroy path). PR bot comment as the goal's table: `env | cluster | ADD | CHANGE | DESTROY | Job link`.

**6. Wiz-scan workflow** (`wiz-scan.yaml`). On PR, detect **new `self_built` entries using `match: equals` only** (only `equals` yields a FQIN). Build a **flattened** `{cluster, image}` matrix (GH Actions can't nest), run parallel jobs: `docker pull` → `wizcli scan container-image "$IMAGE" --policies "cst-container-vuln-<CLUSTER>"`. A scan **failure is the desired signal** (image has vulns → exemption justified) → add label `No Exemption Required`; capture the exit code without failing the job. Bot comment grouped by env → cluster → `image | result | Job link`.

<user_response> 
  Park Wiz-scan workflow this for now. just create an empty file.
</user_response> 

**7. Reusable `unikube.yaml`.** Rewrite the tenant-facing workflow to the consolidated model: inputs `image`, `tag`, `target_clusters`; per target → `docker pull/build` → `wizcli scan ... --policies cst-container-vuln-<CLUSTER>` → on pass `wiz tag`. Drop the secrets/malware `--policy` lines from the current version.

**8. CODEOWNERS.** Three actors on path granularity: security owns `schemas/`, CODEOWNERS itself, and prod paths; platform team owns `exemptions/unikube/**`; customers own their specific cluster files. Prod (`exemptions/unikube/prod/**`, `preprod/**`) gets a stricter reviewer set (separate approval, per resolved decision).

**9. Reconcile stale artifacts.** Rewrite root + interface `README.md` to the consolidated model; remove/superscede `version.yaml`, `exemptions_build/`, `exemptions_deploy/` references; keep `exemptions/pck/` untouched (out of scope).

**10. Verification.** Run `validate.py` on all cluster files; run `compute_matrix.py` against a synthetic diff for each case (cluster edit, global edit, delete); `terraform validate` + `mock_plan.py` on the example tfvars; lint workflows (actionlint) and confirm matrix JSON parses. Document results.

## Pitfalls

- **Golden-default state contention.** If `cst-container-vuln-default` lives in per-cluster state, 200 clusters each try to own the same object → drift and lock fights. Must be a separate bootstrap state; per-cluster policies reference it read-only.

<user_response> 
  As mentioned before, Yes `cst-container-vuln-default` is a special case, and require it's own statefile.
  cluster state file should only logically reference this configuration.
</user_response> 

- **`global.yaml` fan-out at scale.** A one-line global change fans to ~200 parallel applies → GH Actions concurrency ceilings and S3/DynamoDB lock pressure. Need concurrency groups and possibly batching/throttling.

<user_response> 
  Ignore this issue for now. Currently should be manageable
</user_response> 

- **Nested matrix.** cluster × image isn't expressible as a native nested GH Actions matrix — precompute a flat pair list in `compute_matrix.py`.

- **Inverted scan semantics.** `wizcli scan` exit ≠ 0 is a *pass* for the exemption case. Getting the `continue-on-error` / exit-code capture wrong will either fail good PRs or mislabel them.

<user_response> 
  Since wiz scan workflow is parked for now, no need to worry about it here.
</user_response> 

- **FQIN only from `equals`.** `starts_with` self-built entries must be excluded from the scan matrix — they have no concrete FQIN to pull/scan.

<user_response> 
  Since wiz scan workflow is parked for now, no need to worry about it here.
</user_response> 

- **Delete path + state cleanup.** Detecting a deleted cluster file and destroying its 5 objects is easy to miss; orphaned S3 state must also be handled.

<user_response> 
  Yes add code to delete S3 statefil object as well
</user_response> 

- **`wiz-policies.tf` linkage bug** (line 88) and empty `name`/`description` fields — the template won't produce distinct per-cluster names until wired to variables.

<user_response> 
  Fix the linkage bug
  You figure out short, concise and proper templating for `name`/`description`
</user_response> 

- **Blackbox provider schema.** `wiz-v2_*` resource/attribute names are unverified against the real provider — non-blocking for scaffolding, but flagged for the Wiz spike.

- **Build-before-scan ordering.** A cluster's policies/ignore rules must exist in Wiz *before* a tenant scans against them: exemption PR merged → CD applies → tenant re-runs `unikube.yaml`. Document in tenant-facing docs.

<user_response> 
  Acknowledged. Since skipping wiz scan workflow for now, no need to address.
</user_response> 

- **Per-cluster vs global version pin.** Mixed pins across cluster files (v1.0.0 vs v2.0.0) mean the engine is cloned at different tags per matrix job — the action must pin per-cluster, not globally.

<user_response> 
  cluster pinning will always trump global pinning. Is that doable?
</user_response> 

## Deliverable

This plan is documentation only — no code is written yet. On approval I'll execute steps 1–10 and land the full scaffold across both repos.

<user_response> 

Implementation Notes:

- Cater for local testing as well. Meaning give user instructions to run the terraform plan, approve for an env/cluster if user is inside `container-vulnerability-exemption`. For local testing then it should always reference local repo `container-vulnerability-exemption-tf` HEAD? To connect to wiz, user will provide environment variable: WIZ_CLIENT_ID and WIZ_CLIENT_SECRET.

- Add instructions to any other python script locally as well so user can verify. Add simple concise tests for the python scripts.

- `container-vulnerability-exemption-tf/terraform/wiz-policies.tf` is just a reference. Make sure to create best-practice terraform repo structure for `container-vulnerability-exemption-tf` then move `container-vulnerability-exemption-tf/terraform/wiz-policies.tf` to `./out`

</user_response> 
