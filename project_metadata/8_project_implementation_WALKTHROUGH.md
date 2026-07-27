# Implementation Walkthrough

What was built for the consolidated goal in `8_project_implementation_0.md`, and the
decisions from the answered `8_project_implementation_PLAN.md`. Everything is a
runnable mock — no live Wiz tenant required to exercise it.

> Note: a later hardening pass (see `history/improvements.md`) restructured the layout —
> interface config/scripts/tests/schemas are now scoped under `unikube/`, engine
> Terraform under `terraform/`, scripts take `<env>/<cluster>`, and tests use synthetic
> fixtures. `9_project_summary.md` and the repo READMEs reflect the **current** layout;
> paths in the body below describe the original phase-8 build.

## Decisions applied

- **Goal doc is authoritative.** Naming reverted to `cst-container-vuln-*` /
  `cst-container-image-trust-*`; folder is `exemptions/unikube/<env>/`; the policy set
  is Vulnerability + Image-Trust only (no separate secrets/malware). Stale README /
  `ci.yaml` / `cd.yaml` and the `exemptions_build`/`exemptions_deploy` model were removed.
- **`wiz-policies.tf` linkage bug fixed.** In the engine module the Image-Trust policy
  (object 4) now references its own ignore rule (object 5), not the Vulnerability one.
- **Golden default is isolated.** `cst-container-vuln-default` lives in `bootstrap/`
  with its own state; cluster applies only read it (`terraform_remote_state`).
- **Version pinning:** dropped global `version.yaml`; pin lives in `global.yaml`
  (per-env) and may be overridden per cluster. Cluster pin always wins.
- **Enforcement:** per-env in `global.yaml`, overridable per cluster.
- **Wiz-scan workflow parked** (empty placeholder file), per request.
- **Reference relocated:** `container-vulnerability-exemption-tf/terraform/wiz-policies.tf`
  → `out/wiz-policies.tf`; the engine repo was rebuilt as a best-practice module layout.
  `out/` is a gitignored scratch dir, so the parked reference is not committed.

## Interface repo — `container-vulnerability-exemption`

**Schema** (`schemas/`): `exemption.defs.json` (shared exemption + operator +
enforcement defs), `cluster.schema.json`, `global.schema.json`. An exemption is
`{value, operator(equals|starts_with), jiraTicketId, pactId?, approved_by, expiry}`.

**Cluster/global YAMLs** filled in with the real schema: `dev/anp07`, `dev/anp02`
(cluster-level enforcement override + `v2.0.0` pin), `prod/apr01`, and each env's
`global.yaml` (enforcement + env-wide `vendor_or_oss` + engine pin).

**Scripts** (`scripts/`):
- `common.py` — discovery, schema loading (offline `$ref` resolver), and the
  resolution rules (version precedence, enforcement override, vendor merge, operator split).
- `validate.py` — schema + expiry-not-past + duplicate-value checks.
- `compute_matrix.py` — `git diff --name-status` → `[{env,cluster,mode}]`. Cluster
  edit → `apply`; delete → `destroy`; `global.yaml` change → every cluster in the env;
  a cluster's own delete wins over a global-triggered apply.
- `render.py` — merges cluster + env global → engine tfvars JSON (splits `self_built`
  into `name_v2` equals/starts_with and `vendor_or_oss`+env-wide into `image_name`).
- `mock_plan.py` — prints the 5 objects a cluster would create, offline.

**Tests** (`tests/`, pytest): 11 tests covering matrix modes/fan-out/delete-precedence,
operator split + vendor merge, version precedence, enforcement override/default, and a
clean-repo validation pass.

**Workflows** (`.github/`):
- `terraform.yaml` — replaces ci+cd. Validate → compute matrix → per-cluster job;
  PR = `plan`, push-to-main = `plan`+`apply`; Wiz NONPROD then gated Wiz PROD; PR bot
  comment `env|cluster|ADD|CHANGE|DESTROY|Job link`.
- `actions/tf/action.yaml` — render, resolve the per-cluster engine version, obtain the
  engine (pinned tag, or local HEAD via `engine_local_path` for testing), `terraform
  init` with per-cluster S3 key `unikube/wiz-<tenant>/<env>-<cluster>.tfstate`, then
  plan/apply/destroy. On destroy it recovers the deleted file from `HEAD~1`, destroys,
  and `aws s3 rm`s the orphan state object.
- `unikube.yaml` — reusable tenant workflow; scans a built image against
  `cst-container-vuln-<cluster>` per target and `wiz tag`s on pass (secrets/malware lines dropped).
- `wiz-scan.yaml` — parked placeholder.

**CODEOWNERS** — three actors: `@org/security-leads` (schema, CODEOWNERS, all
prod/preprod), `@org/unikube-platform` (all unikube exemptions + automation), and
customer teams co-owning their own cluster file (example on `dev/anp07.yaml`). Prod &
preprod require security as an additional approver.

## Engine repo — `container-vulnerability-exemption-tf`

Best-practice layout: root `main/variables/providers/versions/backend/outputs.tf`,
`modules/cluster_policy_set/` (the 5 parametrised objects, bug fixed, concise
`name`/`description` templating like `cst-container-vuln-<cluster>`), `bootstrap/`
(golden default, own state, outputs `default_policy_id` + `vuln_params`), and
`examples/anp07.auto.tfvars.json`. One apply = one cluster; root reads the golden
bootstrap state read-only and passes its id + baseline params into the module. A
`link_golden_default=false` flag lets a single cluster plan offline.

## Verification performed

- `validate.py` → 7 files valid.
- `render.py` for anp07/anp02/apr01 → correct version precedence (anp02 `v2.0.0`
  trumps env `v1.0.0`), enforcement (apr01 inherits prod `BLOCK`, anp02 overrides to
  `AUDIT`), operator split, and env-wide vendor merge.
- `compute_matrix.py` → cluster-edit, global-fan-out, and delete-precedence cases.
- `pytest` → 11 passed.
- All workflow + action YAML parse; all `.tf` files brace-balanced.

> `terraform validate`/`init` could not run here (the internal `wiz-v2` provider isn't
> on a public registry and the sandbox has no network to install Terraform). Offline
> checks used `mock_plan.py`, the tests, and structural HCL checks; run `terraform fmt`
> / `validate` in an environment with the provider available.

## Follow-ups (out of scope now)

- Un-park and build `wiz-scan.yaml` (flattened `{cluster,image}` matrix; scan-failure =
  "No Exemption Required" label).
- Wire real S3 bucket + DynamoDB lock; plan bootstrap/import for ~200 clusters × 2 tenants.
- Confirm real `wiz-v2` provider attribute names during the Wiz spike.
