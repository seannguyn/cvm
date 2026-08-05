
Actually let's look at a new direction from tweak.md and tweak_PLAN.md

During github action unikube workflow run, when an image is compliant as per standard, if you have to continue to go on and raise compliant PR, that is NOT a good workflow.

Luckily I found out that Wiz `wiz-v2_image_integrity_validator` supports method = `COSIGN` OR `NOTARY`. these 2 methods are mutually exclusive. I add coded here: wiz/container-vulnerability-exemption.tf/terraform/modules/cluster_policy_set/main.tf

So I'm thinking during unikube workflow, if the image is built in a compliant way (check tweak_PLAN.md for compliance already discussed), signed the image either Cosign or Notary v2 (Notation)

Then because the `wiz-v2_image_integrity_validator` have either Cosign or Notary v2 configured, the image is admitted.

So compliant self-built image, also rmb saying why the image is not compliant => signed => pushed => therefore admitted to cluster
non-compliant self-built image, clone the container-vulnerability-exemption, check which cluster is specified, and find if the image beind build matches the exemption regex (via already merged PR), if no then there has been NO exemption. Failed CI with red message saying why the image is not compliant, and ask tenant to raise PR andif yes then continue on the pipeline to push image.

vendor & oss always go through exemption.

I think it is much cleaner this way.

Because this is internal enterprise air-gapped environment, keyless cosign also out the question. It has to follow: CA, private key and signing certificate route. Evaluate whether Cosign or Notary v2 (Notation) is best for the job.

So in this direction, we don't even need individual wiz-v2_cicd_scan_policy.vuln per cluster. We only need a golden wiz-v2_cicd_scan_policy.default_vuln that will scan the image during unikube github action as informational only. the main gate is compliance check + signing. so maybe process is: build image, scan for vulns as information, check for compliance, and sign? or there is a better order, you tell me.

The wiz-v2_cicd_scan_policy.trust have to be per cluster still, because exemption are granular on per cluster basis. The "wiz-v2_image_integrity_validator.validator_match_all" can technically be one, and shared by all cluster wiz-v2_cicd_scan_policy.trust. However, that would mean this will be in boostrap? because current setup is each cluster has its own wiz-v2_cicd_scan_policy.trust and wiz-v2_image_integrity_validator.validator_match_all. Do you think keep current setup? or move wiz-v2_image_integrity_validator.validator_match_all to bootstrap?

So the schema for cluster and global is much simpler now is much simpler:

```yaml
schema_version: "1.0.0"
# env-level engine pin; a cluster file may override with its own pin.
container-vulnerability-exemption-tf_version: v1.0.0

# env-wide admission enforcement, applied to every cluster's Image-Trust policy
# unless the cluster overrides it.
admission:
  enforcement: AUDIT

# env-wide vendor / OSS allowlist merged into every dev cluster.
exemptions:
  - name: # establish a short standardized convention
    image_value: "..."
    operator: # can be one of any: equal, starts_with, matches_regex
    jiraTicketId: SEC-0001
    approved_by: platform-team
    expired_at: "2027-01-01"
  - name: # establish a short standardized convention
    image_value: "..."
    operator: # can be one of any: equal, starts_with, matches_regex
    jiraTicketId: SEC-0001
    approved_by: platform-team
    expired_at: "2027-01-01"
```

The only difference now is that each element in `exemptions` is an ignore_rule, so segregated, with its own expiry. so each cluster will have its tfstate, and each should have:
- 1 wiz-v2_cicd_scan_policy.trust
- many ignore_rule, each name something like:
  - env_cluster_global_name # for the ones defined in global.yaml
  - env_cluster_global_name # for the ones defined in global.yaml
  - env_cluster_name
  - env_cluster_name
  - ...
