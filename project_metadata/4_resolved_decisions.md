# Resolved Decisions (post phase-3)

Locked-in decisions now reflected in the two repos, plus the few questions left
before this is "final."

## Locked

1. **Per-cluster policy sets, no default.** `container-scan-{vulnerability,secrets,
   malware}-<cluster>` + `container-admission-<cluster>` (IMAGE_INTEGRITY, 3 golden
   `*` validators). Admission is cluster-scoped.
2. **Two ignore-rule tiers** (per the Wiz examples image):
   - BUILD — `finding_types=[VULNERABILITY|SECRET|MALWARE]`, `rule_lifecycle_targets=[BUILD]`,
     `resource_conditions.name_v2.equals=[image:tag]`, linked to the scan policy.
     Image still scanned + tagged. Authored in `exemptions_build/<image>.yaml`,
     segregated by tag → finding type.
   - DEPLOY — `finding_types=[IMAGE_INTEGRITY]`, `rule_lifecycle_targets=[DEPLOY]`,
     `image_integrity_finding_conditions.image_name`, linked to the admission policy.
     Platform images (env `global.yaml`, applied to every cluster) + per-cluster
     vendor images (`deploy_ignore_rules`). No scan/tag.
3. **Folder structure** `exemptions_deploy/unikube/{dev,nonprod,preprod,prod}/`;
   cluster files named `<CLUSTER_NAME>.yaml` (globally unique, no account prefix).
   `pck/` is a different team, out of scope.
4. **Promotion axis = Wiz tenant, not k8s env.** All unikube envs land in the same
   Wiz PROD tenant. CD applies to Wiz NONPROD (verify, dummy) → gated approval →
   Wiz PROD (effect). Tenant chosen by SA credentials; one engine version pin.
5. **Enforcement by k8s env** (a real property in Wiz PROD): dev/nonprod = AUDIT,
   preprod/prod = BLOCK. Build scan policies stay BLOCK everywhere.

## Open questions before "final"

1. **Prod exemption gate.** Should a BUILD exemption approved for dev auto-carry to
   the prod cluster file, or require a separate prod-scoped approval? Current mock
   lets it carry (apr01) with a CODEOWNERS note. Recommend: separate approval.
2. **State sharding.** Mock uses one state per Wiz tenant. At ~200 clusters, shard
   further (state key per cluster) so CI plans only changed clusters and blast
   radius is one tenant? Recommend yes for prod.
3. **SECRETS/MALWARE exemption identity.** Schema uses a `finding_id` string. Confirm
   what Wiz actually keys these on (path? rule id? hash) so the ignore rule scopes
   correctly.
4. **Digest vs tag.** BUILD exemptions currently key on `image:tag` (matches the Wiz
   `name_v2.equals` example). Tags are mutable — pin to `@sha256:` digests instead?
5. **max_age policy.** Fixed 2y on validators. Confirm this matches attestation
   freshness requirements.
