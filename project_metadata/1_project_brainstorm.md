# Container Vulnerability Management (AI NOT to modify this file WITHOUT approval)

## Context

- Platform Team X runs 200+ EKS Clusters, and manage all integrations for these clusers. All clusters have Wiz Admission Controller installed
- Consumers/Tenants run their application images on these EKS Clusters
- Images running on clusters can be: from tenants' application image or Platform team X images, such as EBS CSI Driver, ArgoCD, velero, cert-manager, custom application image integration, etc
- These images belong to 2 categories:
  1. self-built from git source code repository + Dockerfile
  2. opensource/vendor images that is mirrored through ECR/Artifactory 
- Some main Wiz resources as named in Wiz Terraform Providers:
  - Data Sources:
    - wiz-v2_cicd_scan_policies
    - wiz-v2_ignore_rules
    - wiz-v2_image_integrity_validators
  - Resources
    - wiz-v2_cicd_scan_policy
    - wiz-v2_ignore_rule
    - wiz-v2_image_integrity_validator

Due to heighten security concern, all images running on clusters must be checked, and admitted by Wiz Admission Controller

For self-built images, the Wiz System for Wiz Admission Controller works like this:

1. Build (CICD) phase: 
  - For self-built image, it has to go from: git source code repository --> CICD 
  - During CICD, users run `docker build` then `wiz scan --policies` where `example_image:1.0` is scanned against `wiz-v2_cicd_scan_policy` of `TYPE=VULNERABILITIES,SECRETS,MALWARE`, let's say these policies are named `container-scan-vulnerability-default`, `container-scan-secrets-default`, `container-scan-malware-default` in Wiz.
    - If Wiz scan PASS, `wiz tag example_image:1.0` means that `example_image:1.0` is in Wiz trusted image database with attestation: `example_image:1.0` has passed CICD mentioned above. Then `docker push example_image:1.0` to Artifactory or ECR. Pipeline SUCCEED.
    - If Wiz scan FAIL, CICD exit non-zero, and pipeline FAIL.
2. Deploy phase
  - On each k8s cluster, Wiz Admission Controller runs, and it one or more `wiz-v2_cicd_scan_policy` of `TYPE=IMAGE_INTEGRITY`. each `wiz-v2_cicd_scan_policy` of `TYPE=IMAGE_INTEGRITY` contains one or more `wiz-v2_image_integrity_validators`, which are combination of: image_patterns (set of string), value.wiz_scan (one wiz-v2_cicd_scan_policy id). 
  - This means that for a k8s cluster, it have one `wiz-v2_cicd_scan_policy` of `TYPE=IMAGE_INTEGRITY` and `ENFORCEMENT=BLOCK or AUDIT` with `fail_untested_image=true` and 3 golden `wiz-v2_image_integrity_validator`:
    - image_patterns = `*`, `wiz-v2_cicd_scan_policy` id = `container-scan-vulnerability-default`
    - image_patterns = `*`, `wiz-v2_cicd_scan_policy` id = `container-scan-secrets-default`
    - image_patterns = `*`, `wiz-v2_cicd_scan_policy` id = `container-scan-malware-default`
  - If `example_image:1.0` PASS all of these `wiz-v2_cicd_scan_policy` named `container-scan-vulnerability-default`, `container-scan-secrets-default`, `container-scan-malware-default` during Build phase, example_image:1.0 is admitted to run by Wiz Admission Controller.
  - If `example_image:1.0` FAILS any of these (one or more) `wiz-v2_cicd_scan_policy` during Build phase, `example_image:1.0` was never `wiz tag` hence `example_image:1.0` is BLOCKED. if  `wiz-v2_cicd_scan_policy` of `TYPE=IMAGE_INTEGRITY` and `ENFORCEMENT=BLOCK`. Concrete example, let's say `example_image:1.0` FAILS `container-scan-vulnerability-default`
    - There are 2 workarounds:
      1. Tenant patch the risk by updating code, run CICD pipeline again, `wiz scan --policies` where `example_image:1.0` is scanned against `container-scan-vulnerability-default`, `container-scan-secrets-default`, `container-scan-malware-default`, it passes, then `wiz tag example_image:1.0` means that `example_image:1.0` is in Wiz trusted image database with attestation: `example_image:1.0` and wiz admission controller will allow deployment
      
      2. Tenant accept the risk, so during Build phase, tenant create `wiz-v2_ignore_rule` in the policies that `example_image:1.0` FAILED, so it can be `container-scan-vulnerability-default`, `container-scan-secrets-default`, `container-scan-malware-default`. For example if `example_image:1.0` failed `container-scan-vulnerability-default` because of CRITICAL CVE-2025-12345, then add
       `wiz-v2_ignore_rule` that says: ignore CVE-2023-12345 for image `example_image:1.0`. Run CICD pipeline again, `wiz scan example_image:1.0 --policies` should PASS, and wiz tag `example_image:1.0` is allowed. Then `example_image:1.0` is allowed to run by Wiz Admission Controller

For opensource/vendor images, the Wiz System for Wiz Admission Controller works like this:

- There is no CICD phase, since these images are opensource, or vendor provided, and these images simply exists in Artifactory/ECR that EKS already have connectivity and permission to pull
- When users deploy these images, it will fail since there is no `wiz tag` for these images, these images are untested, and our `wiz-v2_cicd_scan_policy` of `TYPE=IMAGE_INTEGRITY` and `ENFORCEMENT=BLOCK or AUDIT` with `fail_untested_image=true` will theoretically block deployment, because `fail_untested_image=true`.
- To allow these images to be deploy, and an extra `wiz-v2_ignore_rule` that has wiz-v2_ignore_rule.conditions.image_integrity_finding.image_name.equals = `vendor_image:1.0`,`opensource_image:1.0`. Then Wiz Admission Controller will work allow this `vendor_image:1.0` or `opensource_image:1.0` to be deployed

## Challenges

Now there can be hundreds of git source code repository + Dockerfile" from tenants, as they build their own application image, we can not create just 3 golden policies: `container-scan-vulnerability-default`, `container-scan-secrets-default`, `container-scan-malware-default`, and keep applying all of application images to these policies. Let's say `container-scan-vulnerability-default` have ignore rules for vulns on `tenant_X_image:1.0`, `tenant_Y_image:1.0`, `tenant_Z_image:1.0`, then that means the policies on each tenant_X_k8s, tenant_Y_k8s, tenant_Z_k8s cluster that has the same `wiz-v2_cicd_scan_policy` of `TYPE=IMAGE_INTEGRITY`, which contains one or more `wiz-v2_image_integrity_validators`, which are combination of: image_patterns (set of string), value.wiz_scan (one wiz-v2_cicd_scan_policy id). 
  - This means that for a k8s cluster, it have one `wiz-v2_cicd_scan_policy` of `TYPE=IMAGE_INTEGRITY` and `ENFORCEMENT=BLOCK or AUDIT` with `fail_untested_image=true` and 3 golden `wiz-v2_image_integrity_validator`:
    - image_patterns = `*`, `wiz-v2_cicd_scan_policy` id = `container-scan-vulnerability-default`
    - image_patterns = `*`, `wiz-v2_cicd_scan_policy` id = `container-scan-secrets-default`
    - image_patterns = `*`, `wiz-v2_cicd_scan_policy` id = `container-scan-malware-default`

tenant can just deploy `tenant_X_image:1.0`, `tenant_Y_image:1.0`, `tenant_Z_image:1.0` across clusters that don't belong to them, like `tenant_X_image:1.0` on `tenant_Y_k8s`, `tenant_Z_k8s`.

I think a better solution is:
- each k8s cluster should have their own policies, which follow the rules and template of golden policies. Like for example: 
  - container-scan-vulnerability-tenant_Y_k8s
  - container-scan-secrets-tenant_Y_k8s
  - container-scan-malware-tenant_Y_k8s
  - container-scan-vulnerability-tenant_Z_k8s
  - container-scan-secrets-tenant_Z_k8s
  - container-scan-malware-tenant_Z_k8s
which follows the rules and template of golden policies `container-scan-vulnerability-default`, `container-scan-secrets-default`, `container-scan-malware-default`. But each cluster policies, only have `wiz-v2_ignore_rule` for their own images. so container-scan-vulnerability-tenant_Y_k8s only contains ignore rules for `tenant_Y_image:1.0`, and so on.

- This means that there is granular control per image per clusters, instead of having a big policy with many ignore rules for many images, and blanket apply this to all clusters. S

- So I'm thinking of creating a repository, let's called `policy_control` that have folder structure looking like this:
```
.
├── .github/
│   └── workflows/
│       ├── cd.yaml
│       └── ci.yaml
├── exemptions_build/
│   ├── global.yaml
│   ├── docker.io_library_nginx.yaml
│   ├── tenant_Y_image.yaml
│   ├── ghcr.io_dexidp_dex.yaml
│   └── quay.io_argoproj_argocd.yaml
└── exemptions_deploy/
    ├── ga-nonp/
    │   ├── AWS_ACCOUNT_ID_CLUSTER_NAME.yaml
    │   ├── AWS_ACCOUNT_ID_CLUSTER_NAME.yaml
    │   └── global.yaml
    └── ga-prod/
        ├── AWS_ACCOUNT_ID_CLUSTER_NAME.yaml
        ├── AWS_ACCOUNT_ID_CLUSTER_NAME.yaml
        └── global.yaml
```
- This repo contains `*.yaml` files that expose limited fields for modification. It acts as an interface for users:
  - understand the configuration of golden default `wiz-v2_cicd_scan_policy` like: `container-scan-vulnerability-default`, `container-scan-secrets-default`, `container-scan-malware-default`.
ga-nonp/global.yaml and ga-prod/global.yaml will contains the golden template policies, and each cluster yaml: AWS_ACCOUNT_ID_CLUSTER_NAME.yaml will have its own instance of the golden policies like: `container-scan-vulnerability-tenant_Y_k8s`, `container-scan-secrets-tenant_Y_k8s`, `container-scan-malware-tenant_Y_k8s`.

End to end workflow may look like this:
- Tenant request a k8s clusters, clusters is created via terraform - this process is already in place
- It also creates a `AWS_ACCOUNT_ID_CLUSTER_NAME.yaml` configuration in `policy_control`, which there will be some github actions CD that will create `container-scan-vulnerability-tenant_Y_k8s`, `container-scan-secrets-tenant_Y_k8s`, `container-scan-malware-tenant_Y_k8s`
- Create a `reusable github workflow` that tenant can use to specify: image name, image tag, k8s to be deploy to.
- In tenant git source code repository + Dockerfile", they can use this `reusable github workflow` as part of CICD. The `reusable github workflow` should do wiz scan their built image for vulnerabilities, secrets, and malware. 
  - if success, wiz tag, then when tenant deploy to a cluster, like: tenant_Y_k8s it should be allowed because `reusable github workflow` wiz scan the image with tenant_Y_k8s policies, success, and wiz tag
  - if fail, tenant have 2 options: 
    1. they fix image issues, rerun `reusable github workflow` success, and allow to deploy
    2. they raise PR for exemption in `policy_control` repo, under exemptions_build/tenant_Y_image.yaml, add details there. and also specify that exemptions_deploy/AWS_ACCOUNT_ID_CLUSTER_NAME.yaml should allow this image. In this way, exemptions_deploy/AWS_ACCOUNT_ID_tenant_Y_k8s.yaml can deploy that image, or if any other exemptions_deploy/AWS_ACCOUNT_ID_CLUSTER_NAME.yaml wants to deploy the image, they just reference the details in exemptions_build/tenant_Y_image.yaml.

So `policy_control` is only the yaml configuration repo, which is an abstracted interface for user to interact with. There should be another repo that uses Wiz Terraform provider as an engine to actually create these policies
















