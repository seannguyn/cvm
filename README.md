# Container Vulnerability Management

Mock implementation of the two-repo system for managing Wiz Admission Controller
policies across 200+ EKS clusters. Design rationale in
[`project_metadata/2_design_brainstorm.md`](project_metadata/2_design_brainstorm.md).

## The two repos

| Repo | Role | Who touches it |
|------|------|----------------|
| [`container-vulnerability-exemption`](container-vulnerability-exemption) | YAML **interface** — schema-validated config that tenants and Security edit | Tenants + Security |
| [`container-vulnerability-exemption-tf`](container-vulnerability-exemption-tf) | Terraform **engine** — turns config into Wiz policies (blackbox provider), git-tag versioned | Platform/Security only |

## Core design decision

Every cluster owns its **own** policy set — no default policy shared across
clusters. Admission is therefore **cluster-scoped**: an image runs on a cluster
only if it was scanned and `wiz tag`-ed against **that cluster's** build policy.
This closes both clean-image sprawl and exemption leakage. The one deliberate
exception is a shared **platform baseline** policy for common platform images
(ArgoCD, EBS CSI, cert-manager, velero) that run on every cluster.

## Try the pipeline (no Wiz tenant needed)

```bash
cd container-vulnerability-exemption
pip install pyyaml jsonschema --break-system-packages
python3 scripts/validate.py      # schema-validate the YAML interface
python3 scripts/mock_plan.py     # see the Wiz objects that would be created
```

`scripts/render.py` produces the JSON the Terraform engine consumes
(`container-vulnerability-exemption-tf/examples/rendered.auto.tfvars.json`).

## Flow

1. Tenant edits their `exemptions_build/<image>.yaml` and/or cluster file → PR.
2. **CI** (`ci.yaml`): validate → render → plan.
3. Security approves (CODEOWNERS + branch protection).
4. Merge → **CD** (`cd.yaml`): render → `terraform apply` per-cluster, nonp before prod.
5. Tenant CICD calls `reusable-wiz-scan.yaml` to scan/tag images against their
   target cluster's policies at build time.
