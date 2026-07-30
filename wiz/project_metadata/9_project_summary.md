# Project Summary — Container Vulnerability Exemption

The single entry point for understanding this project. Read this, then the two repo
READMEs it points to, and you know the system end to end:

- **[`container-vulnerability-exemption/unikube/README.md`](../container-vulnerability-exemption/unikube/README.md)** — the interface repo (unikube platform): cluster YAML schema, the local verify/plan commands, the scripts. (The repo root README just routes between platforms.)
- **[`container-vulnerability-exemption-tf/README.md`](../container-vulnerability-exemption-tf/README.md)** — the engine repo: module layout, the 5 objects, state model, bootstrap, local plan.

`8_project_implementation_0.md` is the authoritative goal, `8_project_implementation_PLAN.md`
the answered plan, and `8_project_implementation_WALKTHROUGH.md` records what was built.
Earlier brainstorming (`1`–`7`) is **obsolete** and archived under `project_metadata/history/`
for provenance only — do not treat it as current.

## What this system does

It lets teams manage Wiz container-vulnerability **exemptions** and **admission** for the
unikube EKS fleet (200+ clusters) through reviewed YAML instead of clicking in Wiz.
Customers declare which images may be exempted on their cluster; CI validates and turns
that YAML into Wiz policies via Terraform. Blast radius is one cluster per change.

## The two repos

| Repo | Role | Who edits it |
|------|------|--------------|
| `container-vulnerability-exemption` | YAML **interface** — schema-validated config, CI, CODEOWNERS | Customers + Platform + Security |
| `container-vulnerability-exemption-tf` | Terraform **engine** — creates the Wiz resources, git-tag versioned | Platform / Security |

Each platform is scoped under its own directory in the interface repo
(`unikube/{exemptions,schemas,scripts,tests}`; `pck/` is a stub for a future team), and
all engine Terraform lives under `container-vulnerability-exemption-tf/terraform/`.

**How they connect:** the interface repo's `unikube/scripts/render.py` turns a cluster's
YAML (addressed as `<env>/<cluster>`, e.g. `dev/anp07`) into a `*.auto.tfvars.json`
contract; the `.github/actions/tf` composite action clones the engine at the version the
cluster pins and runs `terraform plan/apply/destroy` against that cluster's own state.
The engine is never edited by customers.

## The 5 Wiz objects per cluster

Every cluster gets exactly five objects (defined in
`container-vulnerability-exemption-tf/terraform/modules/cluster_policy_set`):

1. `wiz-v2_cicd_scan_policy` **`cst-container-vuln-<env>-<cluster>`** — Vulnerability scan policy, a separate instance copying the golden default's baseline params.
2. `wiz-v2_ignore_rule` **`cst-container-vuln-ignore-<env>-<cluster>`** — self-built exemptions (`name_v2` equals/starts_with).
3. `wiz-v2_image_integrity_validator` **`match-all-<env>-<cluster>`** — attestation check.
4. `wiz-v2_cicd_scan_policy` **`cst-container-image-trust-<env>-<cluster>`** — Image-Trust admission policy (AUDIT/BLOCK).
5. `wiz-v2_ignore_rule` **`cst-container-image-trust-ignore-<env>-<cluster>`** — vendor/OSS allowlist (`image_name` equals/starts_with).

The `equals`/`starts_with` lists on objects 2 and 5 are the only customer-editable
fields; they are fed from the cluster YAML's `self_built` and `vendor_or_oss` entries.

## The two exemption types

| Type | YAML key | Maps to | Behaviour |
|------|----------|---------|-----------|
| **Self-built** | `self_built` | Vulnerability ignore rule (`name_v2`) | Image goes through CICD; still **scanned + tagged** by the tenant via `unikube.yaml`. |
| **Vendor / OSS** | `vendor_or_oss` | Image-Trust ignore rule (`image_name`) | Built externally; allowed by name past the trust check, **not scanned**. |

`operator: equals` gives a Fully Qualified Image Name (repo:tag); `operator: starts_with`
gives a prefix. Business fields (`jiraTicketId`, `pactId`, `approved_by`, `expiry`) are
validated but never reach Wiz.

## Key decisions

1. **Goal doc is authoritative.** Naming is `cst-container-vuln-*` / `cst-container-image-trust-*`; folder is `unikube/exemptions/<env>/`; policy set is Vulnerability + Image-Trust only (no separate secrets/malware policies).
2. **Golden default is a separate instance, single-sourced from `golden.yaml`.** `unikube/exemptions/golden.yaml` is the one place holding the fleet baseline (`vuln_params`). It renders into the standalone `cst-container-vuln-default` (managed in `terraform/bootstrap/`, own state) **and** into every cluster's `cst-container-vuln-<env>-<cluster>` (a *physically separate* policy copying the same params). Clusters carry no state coupling to bootstrap, so a cluster apply can never drift the baseline — and editing `golden.yaml` changes everyone (no engine bump, no `.tf` edits).
3. **One apply = one cluster.** State key `unikube/wiz-<tenant>/<env>-<cluster>.tfstate`. CI/CD compute which clusters a PR touches and plan/apply only those, in parallel.
4. **Matrix fan-out.** A `<cluster>.yaml` change → that cluster; a `<env>/global.yaml` change → every cluster in the env; a `golden.yaml` change → the golden bootstrap policy **and** every cluster in every env; a deleted cluster file → `destroy` (which also removes the orphan S3 state object). A cluster's own delete wins over a global/golden-triggered apply.
5. **Promotion axis = Wiz tenant, not k8s env.** All unikube envs live in the same Wiz PROD tenant. CD applies to **Wiz NONPROD** (verify) then, after a gated approval, **Wiz PROD** — chosen by which `WIZ_CLIENT_ID` / `WIZ_CLIENT_SECRET` are set.
6. **Enforcement per env, overridable per cluster.** `admission.enforcement` (AUDIT/BLOCK) is set in each env's `global.yaml` and may be overridden in a cluster file.
7. **Version + schema pinning.** Both the engine version and `schema_version` are pinned per env in `global.yaml`, overridable per cluster; **the cluster pin always wins**. There is no global `version.yaml`.
8. **Fixed reference bug.** In the reference `out/wiz-policies.tf`, the Image-Trust policy linked the *Vulnerability* ignore rule; the module links object 4 → object 5 correctly.
9. **Attestation is per-policy.** Passing `cst-container-vuln-<env>-<cluster>` attests an image only for that cluster; to run on N clusters a tenant scans against each (`unikube.yaml`'s `target_clusters` matrix).
10. **Per-platform layout + isolated tests.** Interface config/scripts/tests/schemas are scoped under `unikube/` (extensible to `pck/`); engine Terraform is all under `terraform/`; scripts address clusters as `<env>/<cluster>`; and the pytest suite runs against synthetic fixtures, never live config.

## How a change flows

**Common mechanics (every change).** A PR touching `unikube/exemptions/**` or
`unikube/schemas/**` runs the `terraform` workflow: a `matrix` job validates the files
and computes the affected set (which clusters + whether the golden changed). On the
**PR** it runs `terraform plan` for each affected cluster (Wiz NONPROD, then gated Wiz
PROD, plan-only) and posts the `env|cluster|ADD|CHANGE|DESTROY|Job link` bot comment. On
**merge to main** it runs `plan`+`apply`, Wiz NONPROD first, then a gated approval, then
Wiz PROD. Each cluster runs in parallel against its **own** state
(`unikube/wiz-<tenant>/<env>-<cluster>.tfstate`), and the engine is cloned at the version
that cluster resolves to (**cluster pin trumps env pin**). Blast radius is one cluster.

The concrete use cases:

**1. Add/modify an exemption on one cluster (most common).**
A tenant edits `unikube/exemptions/<env>/<cluster>.yaml` (a `self_built` or `vendor_or_oss`
entry) → PR → approval → merge. Matrix = that one cluster (`apply`). Its 5 objects are
re-applied, updating the `equals`/`starts_with` lists on the matching ignore rule. For a
new `self_built` entry the tenant then re-runs `unikube.yaml` (use case 7).

**2. Env-wide change via `global.yaml`.**
Edit `unikube/exemptions/<env>/global.yaml` (enforcement, the env-wide `vendor_or_oss`
allowlist, or the env-level version/schema pin) → PR → approval → merge. Matrix = **every
cluster in that env** (`apply`). Each cluster is re-applied: the env-wide vendor allowlist
is merged into each Image-Trust ignore rule, and an enforcement change flips each
cluster's Image-Trust policy (unless that cluster overrides it).

**3. Onboard a new cluster.**
Add `unikube/exemptions/<env>/<cluster>.yaml`. Matrix = that cluster (`apply`, from the
`A` git status). Applying creates its 5 objects and a fresh per-cluster state file. (In a
real deployment this is paired with the cluster-provisioning Terraform that seeds the
YAML + state.)

**4. Offboard / delete a cluster.**
Delete `unikube/exemptions/<env>/<cluster>.yaml`. Matrix = that cluster (`destroy`, from
the `D` status; a delete wins over any global-triggered apply). On merge, `terraform
destroy` removes the 5 objects and the `tf` action deletes the orphan S3 state object.

**5. Roll out a new engine/schema version (canary → env → promote envs).**
Platform changes the engine module (e.g. a new field/resource), cuts a new tag
(`v3.0.0`), and updates the schema (new fields, `schema_version: 2.0.0`).

- **Canary one cluster:** a PR sets `container-vulnerability-exemption-tf_version: v3.0.0`
  (and `schema_version: 2.0.0`, using the new fields) on a **single** cluster file. Since
  the cluster pin trumps the env pin, only that cluster clones `v3.0.0`; the rest of the
  env stays put. Verify it in Wiz NONPROD/PROD.
- **Roll the env:** bump the same pins in that env's `global.yaml` → fans out to every
  cluster in the env (the canary keeps its pin; the rest move to `v3.0.0`).
- **Promote across envs:** repeat the `global.yaml` bump env by env, lower → upper
  (dev → nonprod → preprod → prod), each a separate reviewed PR.
- Every individual apply still runs Wiz NONPROD → gated PROD; the k8s-env progression is
  the human roll-forward across successive PRs.

**6. Change the golden baseline values.**
Edit `unikube/exemptions/golden.yaml` (`vuln_params`) → PR → approval → merge. Matrix =
the golden bootstrap policy **and every cluster in every env**. CI applies
`cst-container-vuln-default` (its own NONPROD → gated PROD bootstrap jobs) and re-applies
every cluster so each `cst-container-vuln-<env>-<cluster>` copies the new baseline. **No version
bump, no `.tf` edits** — this is a pure value change.

- *Adding a new golden policy **type*** (e.g. secrets) is **not** this case: it changes
  the engine module code (new resources + render + schema), so it follows use case 5 —
  cut a new engine tag and bump the version pin — plus adding the new params to `golden.yaml`.

**7. Tenant admits a self-built image (in their own repo).**
After the exemption PR from use case 1 is merged and applied, the tenant calls the
reusable `unikube.yaml` (`image`, `tag`, `target_clusters`): it builds, `wizcli scan`s
against each target cluster's `cst-container-vuln-<env>-<cluster>`, and `wiz tag`s on pass so
that cluster's admission controller trusts the image. **Ordering matters:** the policy +
ignore rule must already exist in Wiz (steps above merged + applied) before the tenant
scans, or the scan still fails.

## Ownership (CODEOWNERS, three actors)

Security (`@org/security-leads`), platform (`@org/unikube-platform`), and customer teams
who co-own their own cluster file. `CODEOWNERS`, and all `preprod/` + `prod/` changes,
require security as an additional approver (the separate prod approval gate). `pck/` is a
different team, out of scope. See `container-vulnerability-exemption/CODEOWNERS`.

## Repository-specific detail

For anything below the level of this summary, go to the repo README:

- Cluster/global YAML shape, `operator` semantics, local `venv` + verify commands, and
  `local_tf.sh` plan/apply with per-cluster local state →
  [`container-vulnerability-exemption/unikube/README.md`](../container-vulnerability-exemption/unikube/README.md).
- Engine module/bootstrap layout, the golden-default mechanics (single-sourced from
  `golden.yaml`, no state coupling) + full bootstrap run, S3 backend + state key, and
  provider notes →
  [`container-vulnerability-exemption-tf/README.md`](../container-vulnerability-exemption-tf/README.md).

## Follow-ups (out of scope now)

Carried forward from `8_project_implementation_WALKTHROUGH.md` — known gaps that are
deliberately not built yet:

- **`wiz-scan.yaml` is parked** (empty placeholder). To build: detect new `self_built`
  `operator: equals` entries (FQIN only), build a flattened `{cluster, image}` matrix,
  `wizcli scan` each pair on PRs, and treat a scan **failure** as the desired signal
  (image genuinely has vulns → add the `No Exemption Required` label).
- **Real state backend.** Wire an actual S3 bucket + DynamoDB lock table, and plan the
  bootstrap/import path for ~200 clusters × 2 Wiz tenants (integrate with cluster
  provisioning so a new cluster's YAML + state are created together).
- **Provider schema.** Confirm the real `wiz-v2` resource/attribute names during the Wiz
  spike; the module was built against the blackbox reference and not yet run through
  `terraform validate` with the live provider.
