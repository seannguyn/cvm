## Open questions before "final"

1. **Prod exemption gate.** Should a BUILD exemption approved for dev auto-carry to
   the prod cluster file, or require a separate prod-scoped approval? Current mock
   lets it carry (apr01) with a CODEOWNERS note. Recommend: separate approval.

ANSWER: Separate approval

2. **State sharding.** Mock uses one state per Wiz tenant. At ~200 clusters, shard
   further (state key per cluster) so CI plans only changed clusters and blast
   radius is one tenant? Recommend yes for prod.
   
ANSWER: good idea. Ultimately, it should work like this:

- For each clusters, these are the only policies to be created/modified/deleted:
  - container-scan-vulnerability-<cluster> + ignore_rules for this policy type (tier 2, where wiz scan & wiz tag required of image, scenario A of ![wiz_ignore_rules_example](./assets/wiz_ignore_rules_example.jpg))
  - container-scan-secrets-<cluster> + ignore_rules for this policy type (tier 2, where wiz scan & wiz tag required of image, scenario A of ![wiz_ignore_rules_example](./assets/wiz_ignore_rules_example.jpg))
  - container-scan-malware-<cluster> + ignore_rules for this policy type (tier 2, where wiz scan & wiz tag required of image, scenario A of ![wiz_ignore_rules_example](./assets/wiz_ignore_rules_example.jpg))
  - container-admission-<cluster> + ignore_rules for this policy type (tier 1, where whitelist image pattern allow deploy, scenario B of ![wiz_ignore_rules_example](./assets/wiz_ignore_rules_example.jpg))

- So when tenant raise PR, a step in github actions to generate matrix to check if per cluster any of those policy changes, before `tf plan`, then `tf plan` jobs should run in parrallel, base on generated matrix to change the policies of that clusters. Scenario that cluster-specific policies can change: 
  - any changes in: unikube/ENV/global.yaml ==> this will mean all container-admission-<cluster> will change
  - any changes in: unikube/ENV/<cluster_name>.yaml ==> specifically for that cluster, so this will mean container-admission-<cluster_name> will change
  - any changes in: container-vulnerability-exemption/exemptions_build/tenant_Y_image.yaml + image tag, and any clusters that uses this tenant_Y_image:1.0.0 ==> specifically for that cluster, so this will mean container-admission-<cluster_name> will change because there are some new exemption for that image: tenant_Y_image tag:1.0.0
  - any changes in container-vulnerability-exemption/exemptions_build/global.yaml ==> this will mean potentially container-scan-vulnerability-<cluster>, container-scan-secrets-<cluster>, container-scan-malware-<cluster> will change for all clusters

- So each cluster will have their own state file, and during CI tf plan, it should fetch that cluster tf state file. Assume that these are stored in AWS S3

- Currently I see inconsistency between container-vulnerability-exemption/.github/workflows/ci.yaml and container-vulnerability-exemption/.github/workflows/cd.yaml. Ideally it should be the quite similar:
```yaml
# ci.yaml
jobs:
  wiz-nonprod:
    compute matrix for changes
    tf plan only
  wiz-prod:
    compute matrix for changes
    tf plan only

# cd.yaml
jobs:
  wiz-nonprod:
    compute matrix for changes
    tf plan
    tf apply
  wiz-prod:
    compute matrix for changes
    tf plan
    tf apply
```

3. **SECRETS/MALWARE exemption identity.** Schema uses a `finding_id` string. Confirm
   what Wiz actually keys these on (path? rule id? hash) so the ignore rule scopes
   correctly.
   
ANSWWER: treat the VULNERABILITY,SECRETS,MALWARE under exemptions to be blackbox. It should be something like:
   ```
   exemptions:
      VULNERABILITIES:
        - reason: "No upstream fix; vulnerable code path not reachable in our config."
          ticket: SEC-1234
          approved_by: security-team
          property: # this should match whatever the vulnerability findings of Wiz terraform say, treat as blackbox for no2
            cve: CVE-2025-12345
      SECRETS:
        - # same as above
      MALWARE:
        - # same as above
   ```

4. **Digest vs tag.** BUILD exemptions currently key on `image:tag` (matches the Wiz
   `name_v2.equals` example). Tags are mutable — pin to `@sha256:` digests instead?

ANSWWER: yes maybe add field digest underneath? like:
   ```yaml
   "1.0.0":
      digests: "@sha256:abcdef1234567890..."
      exemptions:
        ...
   ```
5. **max_age policy.** Fixed 2y on validators
  ANSWWER: yes this satisfy the attestation freshness for now

## Extra ASK:

1. Rename: container-vulnerability-exemption/.github/workflows/reusable-wiz-scan.yaml to unikube.yaml. This means that any tenant wanting to deploy their self-built application image can use this reusable workflow in their own github repository. variables that should be passed can potentially be:
  - image
  - tag
  - target_clusters, like nonprod/almnn01, prod/almnp02, etc.
