# Implementation Plan — tweak.md (review before build)

Draft plan for the two changes in `tweak.md`. **Nothing is implemented yet** — please
review, answer the open questions inline, and I'll build from your answers.

## What I understand you're changing

1. **Operator collapse.** `equals` + `starts_with` are mutually exclusive in Wiz's
   `name_v2` / `image_name` conditions (setting both makes one override the other).
   Replace both with a single `matches_regex` operator, which subsumes both.

2. **Compliance model replaces the vuln gate.** Admission is no longer "must pass a
   vuln scan"; it's "the image is *compliant by construction* (built on the approved base
   `container-soe.registry.domain/*`) **or** has a manual exemption." Concretely, from
   your edits:
   - `wiz-v2_cicd_scan_policy.vuln` → `AUDIT` (scan is informational only).
   - `wiz-v2_ignore_rule.vuln_ignore` → removed (no vuln ignore rule anymore).
   - The single trust ignore rule splits into **two**:
     - `trust_ignore_compliant` — fed from `compliant_images` (automated via the unikube PR flow).
     - `trust_ignore_exemption` — fed from `exemption` (manual tenant PR, security-approved).
   - New per-cluster / global YAML shape (already in `nonprod/wizn02.yaml`, `nonprod/global.yaml`):
     ```yaml
     exemption:
       - image_regex_pattern: "some.private.registry/repo/image:*"
         jiraTicketId: SEC-5678
         pactId: SYS-def
         approved_by: security-team
         expiry: "2026-12-31"
     compliant_images:
       - image_regex_pattern: "^compliant-registry-2/.*"
     ```

3. **New `self-built-image` repo** simulating a tenant: an alpine+`sleep` Dockerfile and a
   workflow that calls the reusable `unikube.yaml` with a list of target clusters.

4. **`unikube.yaml` becomes a compliance gate:** build the image, decide compliance from
   the base image, and either auto-raise a PR (compliant) or fail and tell the tenant to
   file a manual exemption (non-compliant).

## Proposed changes (by area)

### A. Schema (`unikube/schemas/`)
- Rewrite `exemption.defs.json`: drop `operator`/`value`/`equals`/`starts_with`. Add an
  `exemption` item = `{image_regex_pattern, jiraTicketId, pactId, approved_by, expiry}`
  and a `compliant_image` item = `{image_regex_pattern, ...provenance}` (see Q5).
- `cluster.schema.json`: replace `self_built`/`vendor_or_oss` with `exemption[]` +
  `compliant_images[]`.
- `global.schema.json`: `compliant_images[]` env-wide (+ `exemption[]`? see Q3), keep
  `admission.enforcement` + pins.
- `validate.py`: add a check that every `image_regex_pattern` compiles as a valid regex
  (`re.compile`), plus expiry/dupe checks on `exemption`.

### B. Engine (`terraform/modules/cluster_policy_set`)
- Keep `vuln` policy in `AUDIT`; delete the commented `vuln_ignore` block for good.
- Replace the single `trust_ignore` with `trust_ignore_compliant` and
  `trust_ignore_exemption`, both using `image_name.matches_regex`; link both in
  `trust.ignore_rules`.
- New module vars: `compliant_regex` (list), `exemption_regex` (list). Remove
  `self_built_equals/starts_with`, `vendor_equals/starts_with`.
- `policy_names` output → 5 names: vuln, validator, trust, trust_ignore_compliant,
  trust_ignore_exemption. Root `variables.tf`/`main.tf`/`outputs.tf` updated to match.
- Decide the fate of the `image_integrity_validator` (Q6).

### C. Interface scripts
- `common.py`: drop `split_by_operator`/`merged_vendor`; add `merged_compliant()`
  (env + cluster) and `exemption_regex()` extraction → both return regex lists.
- `render.py`: TFVARS now `cluster_name, env, admission_enforcement, vuln_params,
  compliant_regex, exemption_regex`. (engine/schema version stay metadata.)
- `mock_plan.py`: print the new 5-object set.
- Migrate **all** remaining env/cluster files (`dev/*`, `preprod/*`, `prod/*`) to the new
  schema — today only the two `nonprod` files use it, the rest would fail validation.
- Update tests (fixtures + assertions) for the new keys/regex.

### D. `unikube.yaml` (reusable, runs in tenant repo)
Per target cluster:
1. `docker build` from the tenant Dockerfile.
2. **Compliance check** (Q7): resolve the final base image and test it against the
   standard `^container-soe\.registry\.domain/`. 
3. **Informational scan** (Q6): `wizcli scan ... --policies cst-container-vuln-<env>-<cluster>`
   (AUDIT → never blocks); decide whether `wiz tag` is still needed.
4. **Compliant →** open an auto-merge PR to `container-vulnerability-exemption` adding the
   image regex to the target clusters' `compliant_images`, with durable provenance (Q5).
   **Non-compliant →** fail the job with a message telling the tenant to raise a manual
   `exemption` PR.

### E. New repo `self-built-image/`
- `Dockerfile` (alpine + `sleep`), and `.github/workflows/deploy.yaml` calling
  `org/container-vulnerability-exemption/.github/workflows/unikube.yaml@main` with
  `target_clusters`. Placed as a sibling top-level folder in this mock (Q8).

### F. CODEOWNERS / docs / tests
- Reconcile CODEOWNERS with the compliant-auto vs exemption-manual split (Q4 — likely
  needs separate files).
- Update `9_project_summary.md`, both READMEs, module/bootstrap docs, and the
  "How a change flows" use cases (compliant auto-PR becomes a new flow).

## Open questions (please answer inline)

**Q1 — Regex is authoritative.** Confirm every pattern is a real regex (so the standard
becomes `^container-soe\.registry\.domain/.*`). Your samples use glob-ish `...:*` /
`^...-1/*` — `*` in regex is "zero-or-more of the previous char", so `image:*` matches
`image`, `image:`, `image::`… Should I (a) treat values strictly as regex and fix the
samples, or (b) keep a glob-like DSL and translate to regex? Recommend (a).
<user_response>
real regex and fix the samples
</user_response>

**Q2 — Confirm the 5-object composition.** After the change the module manages: vuln
policy (AUDIT), image-integrity validator, trust policy, `trust_ignore_compliant`,
`trust_ignore_exemption`. No vuln ignore rule. Correct?
<user_response>
yes, but don't delete the vuln ignore rule. just keep it commented out
</user_response>

**Q3 — Is `exemption` allowed env-wide?** `compliant_images` clearly merges env-global +
cluster. Should `exemption` also be allowed in `global.yaml` (env-wide manual
exemptions), or cluster-file only? Recommend cluster-only (keeps blast radius tight).
<user_response>
exemption should be merged as well like compliant_images.
</user_response>

**Q4 — compliant (auto) vs exemption (manual) live in the same file → CODEOWNERS can't
tell them apart.** Auto-merge of a `compliant_images` addition would touch the same
cluster YAML that must require **security approval** for `exemption` changes; path-based
CODEOWNERS can't gate per-key. Recommend splitting per cluster into two files:
`<env>/<cluster>.yaml` (manual: `exemption`, `admission`, pins — security/platform owned)
and `<env>/<cluster>.compliant.yaml` (bot-owned, auto-merge). Agree, or keep one file and
accept that compliant PRs need the same review (i.e. not truly auto)?
<user_response>
can it be a service account approval and auto merge?
</user_response>

**Q5 — Recording *why* an image is compliant (your "expiring link" question).** A GH
Actions run URL/log expires, so it's a poor system of record. Recommendation: store
**durable provenance in the committed YAML** on each `compliant_images` entry, e.g.:
```yaml
compliant_images:
  - image_regex_pattern: "^ecr/tenant_Y_image:.*"
    base_image: "container-soe.registry.domain/alpine:3.20"
    base_image_digest: "sha256:..."
    source_repo: "org/self-built-image"
    source_commit: "abc123"
    source_run: "https://github.com/org/self-built-image/actions/runs/123"  # convenience, may expire
    added_at: "2026-07-30"
```
The digest + commit are the real, permanent evidence; the run URL is a convenience.
(Optional hardening: emit a signed/SLSA attestation and store its digest.) Which fields
do you want required vs optional?
<user_response>
Yes, emit a signed/SLSA attestation and store its digest. expand more on this because I don't have the knowledge in this area.
All required.
</user_response>

**Q6 — Does attestation (`wiz tag`) still matter, or is admission now purely name-based?**
With `failed_images_without_validators = true`, an image with no attestation is blocked
*unless* an ignore rule matches its name. Since compliant + exemption are name-regex
ignore rules, name-matching images are admitted without a scan/tag. So: (a) keep the
`image_integrity_validator` + `wiz tag` as a fallback for images that match no rule, or
(b) drop attestation entirely and make admission 100% name-based (compliant OR
exemption)? Recommend (a) keep the validator, make `wiz tag` optional/informational.
<user_response>
keep the validator, make `wiz tag` optional/informational.
The order of the unikube workflow should be: 
- build image
- check for compliance (can this be before build image?)
  - if no abort
  - if yes, sign, attestation, or whatever is best practice, provenance etc. continue
- still run wiz scan, but the policy is now audit, so it is just informational
- don't wiz tag, since not necessary
</user_response>

**Q7 — Exact compliance rule + how to detect the base image.** 
- Is compliance solely "the final stage's base image is `container-soe.registry.domain/*`"?
- For multi-stage Dockerfiles, "final base image" = the `FROM` of the last stage — correct?
- You mention "checking all the docker image metadata to see when the final base image
  was built." Is there also a **freshness** requirement (base built within N days), or is
  the metadata only used to confirm provenance/digest? If freshness, what's the window?
- Detection method: parse the last `FROM` in the Dockerfile, and/or `docker inspect` the
  built image's base layers/labels. Which is authoritative if they disagree?
<user_response>
- Compliance require all images used in multi-stage Dockerfiles to be approved, so all come from `container-soe.registry.domain/*`
- there also a **freshness** requirement for the final base image
- use both parse the last `FROM` in the Dockerfile, and `docker inspect` the
built image's base layers/labels. docker inspect is authoritative since you can't fake that correct?
</user_response>

**Q8 — Placement + credentials for the tenant repo.**
- Put `self-built-image/` as a new top-level folder in this mock repo? 
- The reusable workflow must open + auto-merge a PR in `container-vulnerability-exemption`
  from the tenant repo. What credential model — a GitHub App token or a PAT passed as a
  secret? (Mock can stub it, but I'll wire the interface.)
<user_response>
Put `self-built-image/` as a new folder in wiz/
a GitHub App token, stub it,
</user_response>

## Pitfalls I already see

- **Regex over-broad.** A sloppy `compliant_images` regex (e.g. `.*`) would admit
  everything. Consider validating patterns are anchored (`^`) and not trivially wildcard.
<user_response>
Yes for compliant images, regex is: "^registry/repo/image:tag$ so it is strict
</user_response>
- **Auto-merge bypasses review.** Whatever opens compliant PRs effectively self-approves;
  the base-image standard check *is* the gate, so it must be trustworthy (Q7) and the bot
  path must be narrowly scoped (Q4).
- **Migration.** All non-`nonprod` env files still use the old `self_built`/`vendor_or_oss`
  schema and will fail the new validator until migrated.
<user_response>
Migrate for me. make sure all files are compliant with new structure
</user_response>
- **`matches_regex` provider support.** Assumed the `wiz-v2` provider exposes
  `matches_regex` on `name_v2`/`image_name`; flag to confirm during the Wiz spike.
