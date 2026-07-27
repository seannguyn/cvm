# Container Vulnerability Management

Mock implementation of the two-repo system for managing Wiz container-vulnerability
exemptions and admission across the unikube fleet. Design notes in `project_metadata/`
(see `8_project_implementation_0.md` for the authoritative goal and
`8_project_implementation_WALKTHROUGH.md` for what was built).

## The two repos

| Repo | Role | Who touches it |
|------|------|----------------|
| [`container-vulnerability-exemption`](container-vulnerability-exemption) | YAML **interface** — schema-validated config | Customers + Platform + Security |
| [`container-vulnerability-exemption-tf`](container-vulnerability-exemption-tf) | Terraform **engine** — creates the Wiz resources (blackbox provider), git-tag versioned | Platform / Security |

The original single-cluster reference the engine module was built from was parked in
`out/` (a gitignored scratch dir), so it is intentionally **not** committed.

## Model

- **5 Wiz objects per cluster:** a Vulnerability scan policy + its ignore rule
  (`self_built`, `name_v2`), an image-integrity validator, an Image-Trust admission
  policy + its ignore rule (`vendor_or_oss`, `image_name`). Named `cst-container-vuln-*`
  and `cst-container-image-trust-*`.
- **Golden default** `cst-container-vuln-default` is fleet-wide, lives in its own
  bootstrap state, and is referenced read-only by each cluster.
- **Promotion axis = Wiz tenant** (`nonprod` → gated → `prod`), chosen by SA
  credentials — not the k8s env.
- **One apply = one cluster**, state key `unikube/wiz-<tenant>/<env>-<cluster>.tfstate`.
  CI/CD compute which clusters a PR touches (a `global.yaml` change fans out to the
  whole env) and plan/apply only those, in parallel.
- **Enforcement** (AUDIT/BLOCK) is set per-env in `global.yaml`, overridable per cluster.
- **Engine version** is pinned per-env in `global.yaml`, overridable per cluster;
  the cluster pin wins.

## Folder shape

```
container-vulnerability-exemption/          # interface
  exemptions/unikube/{dev,nonprod,preprod,prod}/{global,<CLUSTER>}.yaml
  exemptions/pck/                           # different team, out of scope
  schemas/  CODEOWNERS
  scripts/  validate.py compute_matrix.py render.py mock_plan.py common.py
  tests/
  .github/workflows/  terraform.yaml unikube.yaml wiz-scan.yaml(parked)
  .github/actions/tf/  action.yaml
container-vulnerability-exemption-tf/       # engine
  main.tf providers.tf variables.tf versions.tf backend.tf outputs.tf
  modules/cluster_policy_set/               # the 5 objects, one cluster
  bootstrap/                                # golden cst-container-vuln-default, own state
  examples/anp07.auto.tfvars.json
out/wiz-policies.tf                         # original reference (gitignored scratch, not committed)
```

## Try it (no Wiz tenant needed)

```bash
cd container-vulnerability-exemption
pip install pyyaml jsonschema pytest --break-system-packages
python3 scripts/validate.py
python3 scripts/mock_plan.py anp07
python3 -m pytest -q
```

See `container-vulnerability-exemption/README.md` for local plan/apply against a real
Wiz tenant (`WIZ_CLIENT_ID` / `WIZ_CLIENT_SECRET`, local engine HEAD).
