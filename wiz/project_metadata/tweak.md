
1. 
Actually, the equal and starts_with operators are mutually exclusive in:
- wiz-v2_ignore_rule.vuln_ignore.conditions.resource.name_v2
- wiz-v2_ignore_rule.trust_ignore.conditions.image_integrity_finding.image_name

Having them both set will override the other

Solution: let's remove equals, and starts_with operator, and go with matches_regex operator, since it perform the function of both

2. changing requirements relating to ignore rules for images.

Currently the wiz-v2_cicd_scan_policy.vuln is in BLOCK mode, and it will fail the scan if image fail the scan. However, there is new requirements for self-built images, which states that the vulnerability scanning of self-built images are informational only. We are checking for whether the self-built images are built correctly, according to some organizational standard, meaning:
- In the git repository of the self-built images, the Dockerfile is the main source of truth.
- If the final image is based on: container-soe.registry.domain/* then this image should be allowed ---> this is the standard.

ASK:

- Create a repo: self-built-image that simulate self-built image
- it has Dockerfile: something alpine, and just have sleep command
- It should have a github actions that call reusuable workflow container-vulnerability-exemption/.github/workflows/unikube.yaml. an array of clusters should be speficied
  - unikube workflow should have a step that build image from Dockerfile, check if the image used are compliant as per standard, either checking the "FROM" statement, and checking all the docker image metadata to see if when the final base image was built, if everything compliant, it should raise PR with auto-merge to container-vulnerability-exemption to add image to the relevant clusters. Now when the image is compliant, is there a way to save record on the PR to say why it is compliant? maybe like a link to github action build, but this one expires right? What is the best case scenario here?
  
  If things are non-compliant, fail the workflow, and ask tenants to manually raise exemption

Ultimately with the new requirement, whether the image is self-built or vendor/oss, it comes down to "custom" compliant, rather than concrete vulns scan. so maybe changing the terraform structure a bit:

```
# 5. Ignore rule for the Image-Trust policy (vendor/OSS allowlist).
resource "wiz-v2_ignore_rule" "trust_ignore_compliant" {
  name                  = "cst-container-image-trust-ignore-compliant-${local.slug}"
  description           = "Vendor/OSS image allowlist for ${local.slug}."
  finding_types         = ["IMAGE_INTEGRITY"]
  finding_ignore_reason = "RISK_ACCEPTED"
  targets               = ["DEPLOY"]

  conditions = {
    image_integrity_finding = {
      image_name = {
        # EDITABLE via customer facing repos, but it should only be via the unikube PR raising process.
        # compliant images is automated
        matches_regex      = [......]
      }
    }
    resource = {
      build_resource = {}
    }
  }
}

resource "wiz-v2_ignore_rule" "trust_ignore_exemption" {
  name                  = "cst-container-image-trust-ignore-exemption-${local.slug}"
  description           = "Vendor/OSS image allowlist for ${local.slug}."
  finding_types         = ["IMAGE_INTEGRITY"]
  finding_ignore_reason = "RISK_ACCEPTED"
  targets               = ["DEPLOY"]

  conditions = {
    image_integrity_finding = {
      image_name = {
        # EDITABLE via customer facing repos, and tenant will raise PR manually and have security team approved
        matches_regex      = [......]
      }
    }
    resource = {
      build_resource = {}
    }
  }
}
```

I have commented wiz-v2_ignore_rule.vuln_ignore, and put policy wiz-v2_cicd_scan_policy.vuln in AUDIT mode. It is still informational to wiz scan the image during CI, but this is not a hard gate to pass like before. I also make some changes in container-vulnerability-exemption/unikube/exemptions/nonprod/wizn02.yaml and container-vulnerability-exemption/unikube/exemptions/nonprod/global.yaml