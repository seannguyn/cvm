
# Implementation Goal

I have remove a lot of previous implementation that is now irrelevant, and have consolidate implementation goal below.

Project requirements:

There should be 2 repos:

# container-vulnerability-exemption
- config, customer facing repos that customers interact with
- there are 2 types of images that can be deployed to a cluster:
  - self-built: this will correspond to wiz-v2_ignore_rule for wiz-v2_cicd_scan_policy of type: `Vulnerability` because these images will need to go through CICD pipeline
  - vendor and OSS: this will correspond to wiz-v2_ignore_rule for wiz-v2_cicd_scan_policy of type: `Image Trust Policy` because these are built externally.
- so for each cluster that customer owns, customer should be able to configure these 2 types of images for exemption. Make the best practice interface here correspond to the field with comments "# EDITABLE via customer facing repos" in container-vulnerability-exemption-tf/terraform/wiz-policies.tf
- This repo should cater for other fields that is more business/process related: Jira ticket ID, SYSTEM_X_ID, expiry, etc.
- ignore exemption/pck. only focus on exemption/unikube
- CODEOWNERS to clearly demonstrate who can own the the cluster file. There are 3 actors: security, platform team (either pck, unikube, other container platform team), and customers (customers of pck/unikube/other container platform)

For now there should be 2 main github actions

1. Terraform github actions

- When a PR is raised, a terraform github action should check for the changed files in in `container-vulnerability-exemption/exemptions/unikube/ENVIRONMENT/CLUSTER.yaml`, and generate matrix run based on files changed, then spawn individual github actions that do `terraform plan` on each changed file. If `container-vulnerability-exemption/exemptions/unikube/ENVIRONMENT/global.yaml` is changed, matrix should be all the clusters in that environment. Assume the statefile for each cluster is stored in S3 with each state file name: ENVIRONMENT-CLUSTER_NAME.

  - When a cluster is created/modify, for example `container-vulnerability-exemption/exemptions/unikube/dev/anp07.yaml`. After the PR merged to main, github actions should run the latest version of `container-vulnerability-exemption.tf` and creates/modify 5 objects accordingly via `terraform apply`:
  1. wiz-v2_cicd_scan_policy of type: `Vulnerability`
  2. wiz-v2_ignore_rule for 1. wiz-v2_cicd_scan_policy of type: `Vulnerability`
  3. wiz-v2_image_integrity_validator
  4. wiz-v2_cicd_scan_policy of type: `Image Trust Policy`
  5. wiz-v2_ignore_rule for 4.

  - when a cluster is deleted, for example `container-vulnerability-exemption/exemptions/unikube/dev/anp07.yaml`. After the PR merged to main, github actions should run the latest version of `container-vulnerability-exemption.tf` and destroy 5 objects via `terraform apply`:
  1. wiz-v2_cicd_scan_policy of type: `Vulnerability`
  2. wiz-v2_ignore_rule for 1. wiz-v2_cicd_scan_policy of type: `Vulnerability`
  3. wiz-v2_image_integrity_validator
  4. wiz-v2_cicd_scan_policy of type: `Image Trust Policy`
  5. wiz-v2_ignore_rule for 4.

  - git bot should comment on the PR this format:
```md
// should be markdown table below

env|cluster|ADD|CHANGE|DESTROY|Job link
dev|anp07|#terraform resources added|#terraform resources changed|#terraform resources destroy|github action job link
```

2. wiz scan github actions

- When PR is raised cluster file is changed, for example: `container-vulnerability-exemption/exemptions/unikube/dev/anp07.yaml`, find out if new images are being added to OPERATOR "equal" only, because only equal gives docker Fully Qualified Image Name (FQIN) . If yes this is considered an ignore-rules addition PR. Generate matrix to see which images were added, for which clusters. Then run github actions jobs in parrallel, that main perform: `docker pull` then WIZ Scan Command: `wizcli scan container-image "$IMAGE_INPUT" --policies "cst-container-vuln-CLUSTER_NAME"`. so this would mean 2 matrixes? one for clusters, and in that cluster, matrix for the images? since WIZ Scan Command can only scan 1 image at a time. It is expected that the WIZ Scan Command can fail, since these images may have vulnerability. If WIZ Scan Command then that is a positive thing, and labels: "No Exemption Required" should be added to PR.

- git bot should comment on the PR this format:
```md
# Wiz Scan

## dev

### anp07

// markdown table
image|result|Job link
image FQIN|PASS/FAIL|github action job link

### ANOTHER_CLUSTER

// only if it is in the matrix
## nonprod

...

```

And another reusable unikube github actions workflow that customers can use on their own self-built image repo AFTER exemption PR is raised, so that their wiz scan & wiz tag is successful for the image that they build

# container-vulnerability-exemption.tf
- host underlying terraform code & module that will be actually responsible for creating the underlying wiz resources
- Make sure terraform repos follow the best practice

There are 5 objects that terraform should create:
1. wiz-v2_cicd_scan_policy of type: `Vulnerability`
2. wiz-v2_ignore_rule for 1. wiz-v2_cicd_scan_policy of type: `Vulnerability`
3. wiz-v2_image_integrity_validator
4. wiz-v2_cicd_scan_policy of type: `Image Trust Policy`
5. wiz-v2_ignore_rule for 4.

For wiz-v2_cicd_scan_policy of type: `Vulnerability`
  - Create "golden" vulnerability wiz-v2_cicd_scan_policy: `cst-container-vuln-default`
  - For each cluster, then create `cst-container-vuln-CLUSTER_NAME` that is based on `cst-container-vuln-default`
  - Then each cluster owner will have the ability to add wiz-v2_ignore_rule for their own `cst-container-vuln-CLUSTER_NAME`. This isolate `cst-container-vuln-CLUSTER_NAME` and follow best practice

For wiz-v2_cicd_scan_policy of type: `Image Trust Policy`
  - For each cluster, create `cst-container-image-trust-CLUSTER_NAME`
  - Then each cluster owner will have the ability to add wiz-v2_ignore_rule for their own `cst-container-image-trust-CLUSTER_NAME`. This isolate `cst-container-image-trust-CLUSTER_NAME` and follow best practice


Here is the terraform file that can create those 5 objects: container-vulnerability-exemption-tf/terraform/wiz-policies.tf


Implementation node:

- This is mainly for scaffolding purposes. The container-vulnerability-exemption-tf/terraform/wiz-policies.tf is actually valid and working.

- This is productions-grade big tech implementation. container-vulnerability-exemption will contain 200+ clusters from unikube platform
