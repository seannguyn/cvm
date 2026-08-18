# terraform-rework — implementation plan

Brief: `terraform-rework.md`. **Implemented 2026-08-14.**

> ## ⚠ PARTLY SUPERSEDED by [`ignore_rules-rework.md`](ignore_rules-rework.md) (same day)
>
> **Still current:** one state per Wiz tenant, no bootstrap, no golden vuln policy, no
> `compute_matrix.py`, tenant-level version pins, single CI job per tenant, and the fact that
> `<env>/global.yaml` produces a rule SHARED by every cluster in the env.
>
> **Changed**, because Wiz caps ignore rules per tenant:
>
> | this document says | now |
> | --- | --- |
> | one `wiz-v2_ignore_rule` per exemption entry | ONE rule per SCOPE, holding every entry's prefix in its `starts_with` list |
> | `ignore-<env>-global-<name>` / `ignore-<env>-<cluster>-<name>` | `ignore-<env>-global` / `ignore-<env>-<cluster>` |
> | a cluster's `ignore_rules` = env rules + own rules | **at most 2** ids |
> | per-entry `operator` (equals/starts_with/matches_regex) | removed; always `starts_with` |
> | per-entry `expired_at`, widened to end-of-day Sydney | removed entirely, along with the DST fallback in `common.py` |
> | `envs[*].exemptions` / `clusters[*].exemptions` objects | `image_values`: a flat list of prefixes |
>
> The rest of this document — state layout, CI shape, tenants.yaml, deletions — describes the
> code as it stands.

Supersedes the terraform/state/CI sections of `new_direction_PLAN.md`. The **signature-based
admission model is unchanged** — compliant self-built images are still Notation-signed and
admitted fleet-wide by the shared NOTARY validator, non-compliant images still need a merged
exemption. Only the terraform topology, the ignore-rule sharing, and the CI shape change.

## Decisions taken (confirmed)

| # | Decision |
|---|----------|
| 1 | **One statefile per Wiz tenant.** Two keys: `unikube/wiz-nonprod.tfstate`, `unikube/wiz-prod.tfstate`. Same config applied twice; the nonprod → gated-prod promotion survives as two jobs. Collapses today's 2 bootstrap states + N per-cluster states down to 2. |
| 2 | **No bootstrap.** The validator, every cluster's trust policy, and every ignore rule live in that one state. `terraform/bootstrap/` is deleted. |
| 3 | **`golden.yaml` and `wiz-v2_cicd_scan_policy.default_vuln` are deleted**, and the informational Wiz scan step is **removed entirely** from `unikube.yaml`. No terraform-managed scan policy remains anywhere. |
| 4 | **One shared global ignore rule per env.** `global.yaml` exemptions become one rule each per *env* (`ignore-<env>-global-<name>`), referenced by every cluster in that env, instead of being copied per cluster. |
| 5 | **Engine + schema version pins move to Wiz-tenant level** (new `unikube/exemptions/tenants.yaml`). One apply per tenant ⇒ one engine tag per tenant, and the tenant is already the promotion axis. Removed from `cluster.schema.json` / `global.schema.json`. |
| 6 | **`compute_matrix.py` is deleted.** Any change under `unikube/exemptions/**/*.yaml` triggers the single plan/apply. |
| 7 | **Greenfield.** No live state. No `moved{}` blocks, no `terraform import`, no state surgery. |

---

## Target architecture

### Wiz objects, per tenant

```
wiz-v2_image_integrity_validator  cst-container-image-validator-default        x1
wiz-v2_ignore_rule                ignore-<env>-global-<name>                   1 per global.yaml entry per env
wiz-v2_ignore_rule                ignore-<env>-<cluster>-<name>                1 per cluster.yaml entry
wiz-v2_cicd_scan_policy           cst-container-image-trust-<env>-<cluster>    1 per cluster
                                    └─ cst-container-image-validator-default
                                    └─ ignore_rules = [env's global rule ids] + [own rule ids]
```

Both of the trust policy's references are now plain intra-state resource references:
`image_integrity_validator_ids = [wiz-v2_image_integrity_validator.shared.id]` replaces the
`terraform_remote_state` read of the bootstrap output, and `ignore_rules` splices the env's
shared rule ids together with the cluster's own. Neither crosses a state boundary anymore.

Only the **global** rules change name and cardinality. Cluster-own rules keep
`ignore-<env>-<cluster>-<name>` exactly as today. `global` can never collide with a cluster
name because `global.yaml` is excluded from cluster discovery (`iter_cluster_files`).

### Engine layout after

```
terraform/
  backend.tf      partial; key = unikube/wiz-<tenant>.tfstate
  versions.tf     unchanged
  providers.tf    unchanged
  variables.tf    notary_ca_certificates | envs | clusters      (3 vars, all rendered)
  locals.tf       flattening: global rule map, cluster rule map, per-cluster id lookup
  main.tf         validator + 2 ignore-rule for_eaches + trust-policy for_each
  outputs.tf      validator_id, trust_policy_ids, global_ignore_rule_ids, cluster_ignore_rule_ids
  examples/fleet.auto.tfvars.json
```

Deleted: `terraform/bootstrap/**`, `terraform/modules/cluster_policy_set/**`,
`terraform/examples/anp07.auto.tfvars.json`.

**Why the module goes.** `cluster_policy_set` encapsulated "the objects one cluster owns in
its own state". That unit no longer exists — global rules are shared across clusters and the
validator is fleet-wide. A 4-resource root module reads better than root-plus-indirection.
(Alternative if we want the boundary back: keep a `for_each`'d module and pass
`global_ignore_rule_ids` in from root. Cheap to switch later; not worth the layer now.)

**Variables removed from the engine:** `validator_id`, `wiz_env`, `state_bucket`,
`state_region`, `cluster_name`, `env`, `admission_enforcement`, and the whole
`data "terraform_remote_state" "bootstrap"` block. Nothing reads bootstrap state anymore.

### Rendered tfvars (one file for the whole fleet)

```jsonc
{
  "notary_ca_certificates": ["-----BEGIN CERTIFICATE-----\n..."],   // was render_bootstrap.py
  "envs": {
    "dev": { "exemptions": [ { "name": "pub-ecr", "operator": "matches_regex",
                               "value": "^public\\.ecr\\.aws/.*",
                               "expired_at": "2027-01-01T23:59:59+11:00" } ] },
    "nonprod": { "exemptions": [] }, "preprod": { "exemptions": [] }, "prod": { "exemptions": [] }
  },
  "clusters": {
    "dev/anp07": { "env": "dev", "cluster_name": "anp07",
                   "admission_enforcement": "AUDIT",      // already resolved: cluster > env > AUDIT
                   "exemptions": [ /* cluster-own only */ ] }
  }
}
```

`admission_enforcement` is resolved per cluster by `render.py`, so `envs` carries exemptions
only. Deleting a cluster file simply removes its key from `clusters` — terraform destroys the
trust policy and its rules on the next normal apply. No destroy mode, no `git show HEAD~1`
recovery, no orphan-state cleanup.

---

## File-by-file changes

### A. Delete

| Path | Note |
|---|---|
| `unikube/exemptions/golden.yaml` | per brief |
| `unikube/schemas/golden.schema.json` | |
| `unikube/scripts/compute_matrix.py` | one job, no matrix |
| `unikube/scripts/render_bootstrap.py` | folded into `render.py` |
| `unikube/scripts/local_bootstrap.sh` | no bootstrap |
| `unikube/tests/test_compute_matrix.py` | |
| `.github/actions/bootstrap/action.yaml` | |
| `.github/workflows/wiz-scan.yaml` | already parked; the scan it described is now gone |
| `terraform/bootstrap/` (`main.tf`, `versions.tf`, `README.md`) | |
| `terraform/modules/cluster_policy_set/` (5 files) | |
| `terraform/examples/anp07.auto.tfvars.json` | replaced by `fleet.auto.tfvars.json` |

### B. New

- **`unikube/exemptions/tenants.yaml`** — tenant-level pins. Lives *inside* `exemptions/`
  (where `golden.yaml` was) so it is covered by the `exemptions/**` trigger glob for free,
  and is ignored by cluster discovery for the same reason `golden.yaml` was.
  ```yaml
  schema_version: "1.0.0"
  tenants:
    nonprod:
      container-vulnerability-exemption-tf_version: v1.0.0
      schema_version: "1.0.0"
    prod:
      container-vulnerability-exemption-tf_version: v1.0.0
      schema_version: "1.0.0"
  ```
  Bump nonprod → verify → bump prod is now the literal promotion mechanism.
- **`unikube/schemas/tenants.schema.json`** — `additionalProperties: false`, both tenant keys
  required, engine pin matching `^v\d+\.\d+\.\d+$`.
- **`terraform/examples/fleet.auto.tfvars.json`** — offline example of the new shape.

### C. Terraform — `main.tf` / `locals.tf`

```hcl
locals {
  # "<env>/<name>" => rule spec
  global_rules = merge([ for env, e in var.envs : {
    for x in e.exemptions : "${env}/${x.name}" => merge(x, { env = env })
  }]...)

  # "<env>/<cluster>/<name>" => rule spec
  cluster_rules = merge([ for k, c in var.clusters : {
    for x in c.exemptions : "${k}/${x.name}" => merge(x, { cluster_key = k, env = c.env,
                                                           cluster_name = c.cluster_name })
  }]...)
}
```

`ignore_rules` for a cluster = global ids for `c.env` + own ids, both looked up from the
`for_each` resources by key prefix. The existing `expired_at` bare-date safety net
(`...T23:59:59+10:00`) moves from the module into `locals.tf` unchanged.

The `sort(distinct(...))` on `notary_v2` and the no-default + PEM/STUB validation on
`notary_ca_certificates` move from `bootstrap/main.tf` to the root **verbatim** — that
validation is the thing standing between a typo and fleet-wide admission failure.

### D. Python scripts

**`common.py`**
- Remove: `GOLDEN_FILE`, `GOLDEN_FILE` handling, `golden_path()`, `load_golden()`,
  `BASELINE_VULN_PARAMS`, `clusters_in_env()` (only `compute_matrix` used it),
  `resolve_version()` / `resolve_schema_version()` / `_resolve_pin()` (now tenant-level).
- Add: `TENANTS_FILE`, `load_tenants()`, `tenant_pin(tenant, key)`.
- Keep untouched: `load_ca_certs()` and the whole trust-anchor story (content-ordering,
  dedup, `unloaded_cert_files()`), `expiry_timestamp()` + the Sydney DST fallback,
  `iter_cluster_files()`, `parse_target()`, `cluster_path()`, `global_for_env()`.
- Split `merged_exemptions()` into `exemption_specs(data)` (normalize one file's entries) and
  keep `merged_exemptions(cluster_data, global_data)` as a thin wrapper — **`check_exemption.py`
  must keep seeing the merged global+cluster view**, since an image is admissible on a cluster
  whether a global or a cluster rule covers it. Its behaviour does not change.

**`render.py`** — becomes fleet-wide and absorbs `render_bootstrap.py`.
- `render.py` → the single tfvars JSON above (`notary_ca_certificates` + `envs` + `clusters`).
- `render.py --field engine_version --tenant nonprod` → the CI action's engine tag.
- Drop `--cluster` and `--file` (destroy recovery is gone).

**`mock_plan.py`** — prints the whole fleet: the validator, each env's shared global rules
once, then each cluster's trust policy with the global ids it references plus its own rules.
Keep an optional `<env>/<cluster>` positional as a filter view. This is the only offline way
to eyeball the sharing invariant, so it earns its keep.

**`local_tf.sh`** — one local state for the whole fleet. Deletes the entire `validator_id`
resolution dance (`$VALIDATOR_ID`, reading `_bootstrap.tfstate`, the stub, the refuse-to-apply
guard) — the validator is now created by the same apply. Signature becomes
`local_tf.sh <plan|apply|destroy>` with no target.

**`validate.py`** — drop the golden validator; add `tenants.yaml` schema validation. Keep the
trust-anchor checks (`load_ca_certs` + `unloaded_cert_files`) exactly as they are.

**`compliance_check.py`, `check_exemption.py`, `gen_signing_certs.sh`, `sign-image.sh`** — unchanged.

### E. Schemas + exemption files

- `cluster.schema.json`, `global.schema.json`: remove `schema_version` and
  `container-vulnerability-exemption-tf_version`.
- Edit all six existing YAML files (`dev/global`, `nonprod/global`, `nonprod/wizn02`,
  `preprod/global`, `prod/global`, `prod/fsp02`) to drop those two fields; update the
  `-global-` marker comment in `dev/global.yaml` to describe the shared-per-env rule.

### F. CI

**`.github/workflows/terraform.yaml`** — matrix, bootstrap-nonprod and bootstrap-prod jobs all go.

```
validate      → validate.py
wiz-nonprod   → needs validate;    plan (PR) / apply (push), env wiz-nonprod
wiz-prod      → needs wiz-nonprod; plan (PR) / apply (push), env wiz-prod (gated)
comment       → PR only
```

Trigger paths:
```yaml
paths:
  - "unikube/exemptions/**"
  - "unikube/schemas/**"
  - "trust/**"
```

> ⚠️ **`trust/**` must stay in the trigger list.** The brief only names `exemptions/**`, but
> the validator now lives in the main state — if a trust anchor change doesn't trigger the
> apply, a new CA merges reviewed and approved and is **never installed**. That is precisely
> the failure `_is_ca_cert()` and `unloaded_cert_files()` were written to prevent; deleting
> `compute_matrix.py` must not delete the guarantee. Flagging for explicit sign-off.

**`.github/actions/tf/action.yaml`** — inputs shrink to
`wiz_env, action, wiz_client_id, wiz_client_secret, state_bucket, state_region, state_lock_table, engine_repo, engine_local_path`.
Removed: `cluster`, `env`, `mode`, the destroy-recovery step, the S3-state-deletion step, and
the `-var=wiz_env/state_bucket/state_region` passthrough. Engine tag comes from
`render.py --field engine_version --tenant <wiz_env>`.

**`comment` job** — with a single plan we can emit real numbers: save the plan file,
`terraform show -json`, count add/change/destroy. Replaces today's scaffold that guesses
"all"/"-" from the matrix mode. *(Nice-to-have; can land after the core change.)*

**`.github/workflows/unikube.yaml`** — remove the "Wiz scan (informational)" step and the
`cst-container-vuln-default` reference in the header comment. Everything else (build →
compliance → exemption check → login → push → sign) is untouched.

**`CODEOWNERS`** — add `/unikube/exemptions/tenants.yaml @org/unikube-platform @org/security-leads`.
The prod engine pin decides which code touches prod; that deserves the stricter rule.

### G. Tests

- Delete `test_compute_matrix.py`.
- `conftest.py`: drop `golden.yaml` from the synthetic tree, add `tenants.yaml`, drop the two
  pin fields from the fake cluster/global files.
- `test_render.py`: rewrite for the fleet shape — env/cluster exemption split, key uniqueness
  across the whole fleet, resolved enforcement precedence, bare-date expiry widening.
- `test_render_bootstrap.py` → fold into `test_render.py`. **Keep every trust-anchor test
  verbatim** (rename-stability, content-ordering, dedup, STUB rejection, missing-dir failure) —
  only the function under test changes name. These are the highest-value tests in the repo.
- `test_validate.py`: drop the golden case, add a `tenants.yaml` case.
- `test_compliance.py` (617 lines): untouched — `compliance_check.py` is not in scope.
- **New**: an explicit sharing-invariant test — for an env with N clusters and a global
  exemption, the rendered payload contains that exemption **once** under `envs`, not N times
  under `clusters`; and `mock_plan` shows all N trust policies referencing the same rule name.
  That invariant is the point of this rework, so it gets its own test.

### H. Docs

| Doc | Change |
|---|---|
| `unikube/README.md` (526 ln) | largest edit: state model, single job, tenants.yaml, shared global rules, local workflow, removal of golden/bootstrap/matrix |
| `container-vulnerability-exemption.tf/README.md` (115 ln) | new engine layout + variables |
| `container-vulnerability-exemption/README.md`, `wiz/README.md`, root `README.md` | topology paragraphs |
| `trust/README.md` | bootstrap references → main apply |
| `project_metadata/project_summary.md` | current-state entry point |
| `project_metadata/new_direction_PLAN.md` | update its terraform/state/CI sections (ln 134, 380); leave the signature-model sections intact and cross-reference this file |
| `project_metadata/venafi-signing.md` | 4 bootstrap refs (ln 109, 438, 629–630, 657, 666) — **two are relative markdown links to `terraform/bootstrap/main.tf`, which this change deletes**; they must be repointed or they 404 |
| `project_metadata/image-signing-101.md` | ln 72 + 205 `notary_ca_certificate` is now a root var (and plural); ln 174 describes the golden AUDIT scan, which is removed entirely |
| `project_metadata/terraform-rework.md` | leave as the brief |

Optional cleanup while in here: `wiz/out/wiz-policies.tf` is dead scaffolding from the
pre-`new_direction` model (per-cluster `cst-container-vuln-CLUSTER_NAME` BLOCK policies with
empty names). Nothing references it. Suggest deleting it rather than leaving a file that
contradicts the architecture.

Open item: `new_direction_PLAN.md` is currently the "latest implementation record". Default
taken above is *edit in place + cross-reference* rather than moving it to `history/`, because
most of it (the signature model) is still current and burying it would hide live decisions.
Say the word if you'd rather it move.

---

## Risks

1. **Provider assumption — shared ignore rules.** The whole rework rests on the `wiz-v2`
   provider accepting the *same* `wiz-v2_ignore_rule` id in the `ignore_rules` list of
   *multiple* `wiz-v2_cicd_scan_policy` resources. It's a settable list of ids today, which
   suggests yes, but the provider is internal/blackbox and this is unverified.
   **Verify first.** If it rejects sharing, the fallback is per-cluster copies of global rules
   (today's behaviour) and only the state consolidation lands — decisions 1, 2, 3, 5, 6 are
   unaffected.
2. **Blast radius grows, deliberately.** One apply now touches every cluster in a tenant. A
   bad `global.yaml` edit, or a provider error mid-apply, is no longer contained to one
   cluster. The single state lock also serializes concurrent PRs. This is the accepted cost of
   the brief; the PR plan output is the gate.
3. **Silent cluster teardown.** Deleting a cluster file used to route to an explicit
   `terraform destroy`. Now it's an ordinary destroy line in the fleet plan. Better
   (it's visible in the diff) but less loud — worth a note in the PR comment.
4. **No real `terraform plan` in verification.** The `wiz-v2` provider isn't publicly
   fetchable, so `terraform init/validate/plan` can't run here. Verification is limited to
   `terraform fmt -check`, the pytest suite, and `mock_plan.py` — same ceiling as today.
   A first real `plan` against the nonprod tenant is required before this is called done.

## Sequence

1. Verify risk 1 against the provider. *(gate)*
2. Engine: new `variables.tf` / `locals.tf` / `main.tf` / `outputs.tf` / `backend.tf`; delete
   `bootstrap/` + `modules/`; add `fleet.auto.tfvars.json`; `terraform fmt`.
3. Interface: `tenants.yaml` + schema; schema and YAML edits; `common.py`; `render.py`
   (absorbing `render_bootstrap.py`); `validate.py`; `mock_plan.py`; `local_tf.sh`; deletions.
4. CI: `terraform.yaml`, `actions/tf`, delete `actions/bootstrap` + `wiz-scan.yaml`,
   `unikube.yaml` scan-step removal, `CODEOWNERS`.
5. Tests: deletions, rewrites, the new sharing-invariant test. Full suite green.
6. Docs.
7. Final sweep: grep the tree for `golden`, `bootstrap`, `compute_matrix`, `validator_id`,
   `default_vuln`, `vuln_params`, `notary_ca_certificate` (singular), `per-cluster state`,
   `mode: destroy` — every hit outside `project_metadata/history/` must be intentional. Also
   resolve every relative markdown link into `terraform/bootstrap/` and
   `terraform/modules/cluster_policy_set/`, both of which are deleted.

## Deviations from the plan, as built

1. **`trust/**` was kept in the CI path filter** (flagged in the plan, not explicitly signed
   off). Without it a reviewed and merged CA would never be installed.
2. **`WIZ_CLIENT_ID`/`WIZ_CLIENT_SECRET` removed from `unikube.yaml`'s secrets contract.**
   Deleting the scan step removed the only consumer; leaving them `required: true` would make
   every tenant repo hand Wiz credentials to a workflow that never calls Wiz.
3. **`scripts/plan_summary.py` added** (not in the plan). The PR-comment logic was going to
   be an inline heredoc in the workflow — which was also a latent bug, since its `PY`
   terminator was indented and would never have terminated. It is stdlib-only so the
   `comment` job needs no dependency install.
4. **`wiz/out/wiz-policies.tf` deleted** (the optional cleanup the plan suggested).
5. **`new_direction_PLAN.md` kept in place** with a superseded-in-part banner and a
   was/now table, rather than moved to `history/` — most of it (the signature model) is
   still current.

## Not yet verified

- **Shared ignore rules across policies.** Still the load-bearing assumption; there is no way
  to test it without the provider. Confirm before the first apply.
- **No real `terraform` run.** The `wiz-v2` provider is not publicly fetchable and the
  sandbox has no terraform binary, so `fmt`/`validate`/`plan` never ran. The HCL was parsed
  with `python-hcl2` and the object graph (key uniqueness, name algebra, which rules each
  cluster references) was checked by simulating the `for_each` logic against the real
  rendered fleet. That is weaker than `terraform validate` — run `terraform fmt -check` and a
  nonprod `plan` first.
- **`dev` has a shared exemption but no cluster files**, so the apply will create
  `ignore-dev-global-pub-ecr` attached to nothing. Harmless and arguably correct (it applies
  to the first dev cluster onboarded), but it will show in the plan.

## Verified against the tree (2026-08-14)

Every path named above exists. Consumer graph confirmed: `clusters_in_env()` has exactly one
caller (`compute_matrix`, deleted); `resolve_version`/`resolve_schema_version` have exactly
one caller (`render.py`); `merged_exemptions()` has two (`render.py`, `check_exemption.py`) —
which is why it is split rather than replaced. `.gitignore` already excludes
`terraform/out/`, `backend_override.tf` and `*.auto.tfvars.json` with a
`!terraform/examples/*.auto.tfvars.json` negation, so the new `fleet.auto.tfvars.json` will
be tracked without a gitignore edit.
