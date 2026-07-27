# Project Summary — Container Vulnerability Exemption

The single entry point for understanding this project. Read this, then the two repo
READMEs it points to, and you know the system end to end:

- **[`container-vulnerability-exemption/README.md`](../container-vulnerability-exemption/README.md)** — the interface repo: cluster YAML schema, the local verify/plan commands, the scripts.
- **[`container-vulnerability-exemption-tf/README.md`](../container-vulnerability-exemption-tf/README.md)** — the engine repo: module layout, the 5 objects, state model, local plan.

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

**How they connect:** the interface repo's `scripts/render.py` turns a cluster's YAML
into a `*.auto.tfvars.json` contract; the `.github/actions/tf` composite action clones
the engine at the version the cluster pins and runs `terraform plan/apply/destroy`
against that cluster's own state. The engine is never edited by customers.

## The 5 Wiz objects per cluster

Every cluster gets exactly five objects (defined in
`container-vulnerability-exemption-tf/modules/cluster_policy_set`):

1. `wiz-v2_cicd_scan_policy` **`cst-container-vuln-<cluster>`** — Vulnerability scan policy, derived from the golden default.
2. `wiz-v2_ignore_rule` **`cst-container-vuln-ignore-<cluster>`** — self-built exemptions (`name_v2` equals/starts_with).
3. `wiz-v2_image_integrity_validator` **`match-all-<cluster>`** — attestation check.
4. `wiz-v2_cicd_scan_policy` **`cst-container-image-trust-<cluster>`** — Image-Trust admission policy (AUDIT/BLOCK).
5. `wiz-v2_ignore_rule` **`cst-container-image-trust-ignore-<cluster>`** — vendor/OSS allowlist (`image_name` equals/starts_with).

The `equals`/`starts_with` lists on objects 2 and 5 are the only customer-editable
fields; they are fed from the cluster YAML's `self_built` and `vendor_or_oss` entries.

## The two exemption types

| Type | YAML key | Maps to | Behaviour |
|------|----------|---------|-----------|
| **Self-built** | `self_built` | Vulnerability ignore rule (`name_v2`) | Image goes through CICD; still **scanned + tagged** by the tenant via `unikube.yaml`. |
| **Vendor / OSS** | `vendor_or_oss` | Image-Trust ignore rule (`image_name`) | Built externally; allowed by name past the trust check, **not scanned**. |

`operator: equals` gives a Fully Qualified Image Name (repo:tag); `operator: starts_with`
gives a prefix. Business fields (`ticket`, `system_x_id`, `approved_by`, `expiry`) are
validated but never reach Wiz.

## Key decisions

1. **Goal doc is authoritative.** Naming is `cst-container-vuln-*` / `cst-container-image-trust-*`; folder is `exemptions/unikube/<env>/`; policy set is Vulnerability + Image-Trust only (no separate secrets/malware policies).
2. **Golden default is isolated.** `cst-container-vuln-default` is a single fleet-wide object living in `bootstrap/` with its **own** state; per-cluster policies reference it read-only, so a cluster apply can never drift or destroy the fleet baseline.
3. **One apply = one cluster.** State key `unikube/wiz-<tenant>/<env>-<cluster>.tfstate`. CI/CD compute which clusters a PR touches and plan/apply only those, in parallel.
4. **Matrix fan-out.** A `<cluster>.yaml` change → that cluster; a `<env>/global.yaml` change → every cluster in the env; a deleted cluster file → `destroy` (which also removes the orphan S3 state object). A cluster's own delete wins over a global-triggered apply.
5. **Promotion axis = Wiz tenant, not k8s env.** All unikube envs live in the same Wiz PROD tenant. CD applies to **Wiz NONPROD** (verify) then, after a gated approval, **Wiz PROD** — chosen by which `WIZ_CLIENT_ID` / `WIZ_CLIENT_SECRET` are set.
6. **Enforcement per env, overridable per cluster.** `admission.enforcement` (AUDIT/BLOCK) is set in each env's `global.yaml` and may be overridden in a cluster file.
7. **Engine version pinning.** Pinned per env in `global.yaml`, overridable per cluster; **the cluster pin always wins**. There is no global `version.yaml`.
8. **Fixed reference bug.** In the reference `out/wiz-policies.tf`, the Image-Trust policy linked the *Vulnerability* ignore rule; the module links object 4 → object 5 correctly.
9. **Attestation is per-policy.** Passing `cst-container-vuln-<cluster>` attests an image only for that cluster; to run on N clusters a tenant scans against each (`unikube.yaml`'s `target_clusters` matrix).

## How a change flows

**Exemption change (interface repo):**
`edit exemptions/unikube/<env>/<cluster>.yaml` → PR → CI validates + computes the matrix
+ `terraform plan` per affected cluster (NONPROD then PROD, plan-only) + PR bot comment
`env|cluster|ADD|CHANGE|DESTROY|Job link` → merge to main → `plan`+`apply` on Wiz NONPROD,
then gated approval, then Wiz PROD.

**Tenant admitting a self-built image (their own repo):**
after the exemption PR is merged and applied, the tenant calls the reusable
`unikube.yaml` (`image`, `tag`, `target_clusters`) which builds, `wizcli scan`s against
each cluster's `cst-container-vuln-<cluster>`, and `wiz tag`s on pass so admission
trusts it. **Ordering matters:** the policy + ignore rule must exist in Wiz before the
tenant scans, or the scan still fails.

## Ownership (CODEOWNERS, three actors)

Security (`@org/security-leads`), platform (`@org/unikube-platform`), and customer teams
who co-own their own cluster file. `CODEOWNERS`, and all `preprod/` + `prod/` changes,
require security as an additional approver (the separate prod approval gate). `pck/` is a
different team, out of scope. See `container-vulnerability-exemption/CODEOWNERS`.

## Repository-specific detail

For anything below the level of this summary, go to the repo README:

- Cluster/global YAML shape, `operator` semantics, local `venv` + verify commands, and
  local `terraform` plan/apply with per-cluster local state →
  [`container-vulnerability-exemption/README.md`](../container-vulnerability-exemption/README.md).
- Engine module/bootstrap layout, S3 backend + state key, `link_golden_default` offline
  flag, and provider notes →
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
