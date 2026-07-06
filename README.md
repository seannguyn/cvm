# Container Vulnerability Management

Mock implementation of the two-repo system for managing Wiz Admission Controller
policies across the unikube EKS fleet. Design notes in `project_metadata/`.

## The two repos

| Repo | Role | Who touches it |
|------|------|----------------|
| [`container-vulnerability-exemption`](container-vulnerability-exemption) | YAML **interface** — schema-validated config | Tenants + Security |
| [`container-vulnerability-exemption-tf`](container-vulnerability-exemption-tf) | Terraform **engine** — creates Wiz policies (blackbox provider), git-tag versioned | Platform/Security |

## Three decisions locked in phase 3

1. **Per-cluster policies, no default.** Each cluster gets
   `container-scan-{vulnerability,secrets,malware}-<cluster>` +
   `container-admission-<cluster>`. Admission is cluster-scoped.
2. **Two ignore-rule tiers.**
   - *BUILD* — suppress a finding for one `image:tag`, still scanned + tagged
     (tenant self-built images; authored in `exemptions_build/<image>.yaml`,
     segregated by tag).
   - *DEPLOY* — allow an image by name past the trust check, no scan/tag
     (platform + vendor images; authored in the deploy `global.yaml` / cluster files).
3. **Promotion axis = Wiz tenant, not k8s env.** All unikube envs are created in
   the same Wiz PROD tenant. CD applies to **Wiz NONPROD** (verify) then, after a
   gated approval, **Wiz PROD** (effect). Chosen by SA credentials.

## Folder shape

```
container-vulnerability-exemption/
  exemptions_build/{global,<image>}.yaml
  exemptions_deploy/unikube/{dev,nonprod,preprod,prod}/{global,<CLUSTER_NAME>}.yaml
  exemptions_deploy/pck/                     # different team, out of scope
  schemas/  scripts/  .github/workflows/  version.yaml  CODEOWNERS
container-vulnerability-exemption-tf/
  main.tf providers.tf variables.tf versions.tf outputs.tf
  modules/cluster_policy_set/                # blackbox Wiz resources
  examples/rendered.auto.tfvars.json
```

## Try it (no Wiz tenant needed)

```bash
cd container-vulnerability-exemption
pip install pyyaml jsonschema --break-system-packages
python3 scripts/validate.py
python3 scripts/mock_plan.py wiz-nonprod
```
