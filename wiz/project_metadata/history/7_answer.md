1. **Wiz provider schema (highest priority).** Confirm the real resource/attribute
   names the mock assumed: `wiz_ignore_rule` linkage to a policy (`policy_ids`?),
   `resource_conditions.name_v2`, `image_integrity_finding_conditions.image_name`,
   `rule_lifecycle_targets`, `finding_ignore_reason`; and how an `IMAGE_INTEGRITY`
   policy + `image_integrity_validator` are expressed. Drive this off the actual
   `wizio/wiz` (or `tenable/wiz`) provider docs.
   
Answer:

- Yes will confirm later. not important for architecture decision

2. **Attestation scoping — the load-bearing assumption.** The whole isolation model
   assumes that scanning against `container-scan-vulnerability-<cluster>` produces
   an attestation the admission validator for *that* policy checks, so an image
   tagged for cluster A is untested on cluster B. Confirm Wiz attestation is
   **per-policy**, not per-image-global. If it is global, revisit tier-1 design.
   → This is the #1 thing to prove on Wiz NONPROD first.

Answer:
- Yes, wiz attestation is image per-policy, not per-image-global. Meaning that if my_image passes `container-scan-vulnerability-<cluster>` it can only be deployed for that cluster.
- If users want `my_image` to be deployed on `cluster-1` and `cluster-2`, they just scan `container-scan-vulnerability-<cluster-1>` and `container-scan-vulnerability-<cluster-2>`. But from the folder structure, the exemption should be centralized in container-vulnerability-exemption/exemptions_build/my_image.yaml, then users add my_image to whatever clusters they want in `unikube/<ENV>/<CLUSTER>.yaml`

3. **Multi-validator semantics.** Confirm the three `*` validators on the admission
   policy combine as AND (image must satisfy all three), and that `fail_untested_image`
   blocks an image lacking any one attestation.

Answer:
- policy combination is `AND`, meaning images has to passed all.
   
4. **SECRETS / MALWARE `property` shape.** Blackbox today. Confirm the selector
   fields (analog of `vulnerability_ids`) so those ignore rules scope correctly.

Answer: OK

5. **State bootstrapping at scale.** ~200 clusters × 2 Wiz tenants = ~400 state
   files. Need a bootstrap/import path and integration with the existing
   cluster-provisioning Terraform (which should also create the cluster's YAML).

Answer: OK

6. **Confirmations (cheap).** `digest` singular vs list; enforcement matrix
   (currently dev/nonprod=AUDIT, preprod/prod=BLOCK); CI creds via OIDC vs static;
   `@security-leads` group name.

Answer: OK