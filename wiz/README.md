# Container Vulnerability Management

Mock implementation of the two-repo system for managing Wiz container-vulnerability
exemptions and admission across the unikube fleet. Design notes in `project_metadata/`
(`project_summary.md` for current state, `new_direction_PLAN.md` for the signature-based
admission model, `terraform-rework_PLAN.md` for the single-state topology).

## The two repos

| Repo | Role | Who touches it |
|------|------|----------------|
| [`container-vulnerability-exemption`](container-vulnerability-exemption) | YAML **interface** — schema-validated config | Customers + Platform + Security |
| [`container-vulnerability-exemption.tf`](container-vulnerability-exemption.tf) | Terraform **engine** — creates the Wiz resources (blackbox provider), git-tag versioned | Platform / Security |

## Model

- **Admission is by signature.** Compliant self-built images are Notation-signed and admitted
  fleet-wide by the shared NOTARY validator. Non-compliant images need a merged, security-
  approved exemption. There is no vuln scan policy and no compliant allowlist.
- **Wiz objects:** one shared `cst-container-image-validator-default`; one
  `cst-container-image-trust-<env>-<cluster>` Image-Trust policy per cluster; and ignore rules
  at two scopes — `ignore-<env>-global` (ONE per env, shared by every cluster in it) and
  `ignore-<env>-<cluster>` (that cluster's own).
- **Ignore rules are AGGREGATED** because Wiz caps them per tenant: all of a scope's
  exemptions live in one rule's `starts_with` list, so a cluster references **at most two**
  rules however many exemptions it has. The cost: matching is always prefix-based
  (no regex, no exact-match) and **nothing expires** — an exemption lives until its YAML line
  is deleted.
- **One apply = the whole fleet for one Wiz tenant**, state key `unikube/wiz-<tenant>.tfstate`.
  Any change under `unikube/exemptions/**` or `trust/**` triggers one plan per tenant; a
  deleted cluster file is an ordinary destroy in that plan.
- **Promotion axis = Wiz tenant** (`nonprod` → gated → `prod`), chosen by SA credentials —
  not the k8s env.
- **Enforcement** (AUDIT/BLOCK) is set per-env in `global.yaml`, overridable per cluster.
- **Engine + schema version** are pinned per Wiz tenant in `unikube/exemptions/tenants.yaml`
  — one apply per tenant can clone exactly one engine tag, so bumping nonprod, verifying,
  then bumping prod *is* the rollout.

## Folder shape

```
container-vulnerability-exemption/          # interface (per-platform layout)
  README.md  CODEOWNERS
  trust/*.crt                               # NOTARY trust anchors, security-owned
  unikube/                                  # the unikube platform
    exemptions/tenants.yaml                 # engine + schema pins, per Wiz tenant
    exemptions/{dev,nonprod,preprod,prod}/{global,<CLUSTER>}.yaml
    schemas/  scripts/  tests/  README.md
  pck/                                      # different team, out of scope (stub)
  .github/workflows/  terraform.yaml unikube.yaml
  .github/actions/tf/  action.yaml
container-vulnerability-exemption.tf/       # engine
  terraform/
    main.tf locals.tf providers.tf variables.tf versions.tf backend.tf outputs.tf
    examples/fleet.auto.tfvars.json
```

## Try it (no Wiz tenant needed)

```bash
cd container-vulnerability-exemption/unikube
python3 -m venv .venv && source .venv/bin/activate
pip install -r scripts/requirements.txt
python3 scripts/validate.py
python3 scripts/mock_plan.py          # the whole fleet; add <env>/<cluster> to narrow
python3 -m pytest -q
```

See `container-vulnerability-exemption/unikube/README.md` for local plan/apply against a
real Wiz tenant (`WIZ_CLIENT_ID` / `WIZ_CLIENT_SECRET`, local engine HEAD).
