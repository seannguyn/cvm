# Gap Analysis — is the design ready for implementation?

**Verdict: design converged, ready to build.** The load-bearing assumption
(per-policy attestation) is confirmed (see item 2). Remaining items are
implementation-time verifications against Wiz, plus two documented constraints
below — no open architectural decisions. See `7_answer.md` for the raw answers.

## What is settled (no open design questions)

- Per-cluster policy sets, no cross-cluster default. (phase 2–3)
- Two ignore-rule tiers, BUILD (scan) vs DEPLOY (admission), unified `deploy_ignore_rules`
  key for tier-1. (phase 3–4)
- Folder model `exemptions_deploy/unikube/<env>/`, unique cluster names. (phase 3)
- Wiz-tenant promotion (NONPROD → PROD), not k8s-env promotion. (phase 3)
- Per-cluster Terraform state + matrix-driven, parallel, single-cluster plan/apply. (phase 5)
- Blackbox `property` selector + optional `digest` pin on BUILD exemptions. (phase 5)
- Prod/preprod require a separate, stricter approval. (phase 5)
- Reusable tenant workflow `unikube.yaml` (image, tag, target_clusters). (phase 5)

## Verification status (from 7_answer.md)

1. **Wiz provider schema.** OPEN but non-blocking — confirm real resource/attribute
   names (`wiz_ignore_rule` linkage, `resource_conditions.name_v2`,
   `image_integrity_finding_conditions`, `rule_lifecycle_targets`,
   `finding_ignore_reason`, IMAGE_INTEGRITY policy + validator) during the Wiz spike.
   Not an architecture decision.
2. **Attestation scoping — CONFIRMED per-policy.** ✅ Scanning `container-scan-vulnerability-<cluster>`
   attests the image only for that cluster; to run on cluster-1 and cluster-2 the
   tenant scans against each. This is the whole isolation model — validated.
3. **Multi-validator semantics — CONFIRMED AND.** ✅ Image must pass all three
   (vuln + secrets + malware); missing any one attestation blocks. Matches the
   three-`*`-validator design and `unikube.yaml` (scans all three, tags only on pass).
4. **SECRETS / MALWARE `property` shape.** Confirmed blackbox is acceptable for now;
   backfill selector fields when the vuln path is proven on Wiz.
5. **State bootstrapping at scale.** Accepted — plan bootstrap/import for
   ~200 clusters × 2 tenants and integrate with cluster-provisioning Terraform.
6. **Cheap confirmations.** Accepted as-is: `digest` singular; enforcement matrix
   dev/nonprod=AUDIT, preprod/prod=BLOCK; CI creds; `@security-leads` group.

## Documented constraints (consequences of the confirmed answers)

### C1. Build/deploy ordering dependency
Because attestation is per-policy, a cluster's policies and ignore rules must exist
in Wiz **before** a tenant scans against them. Strict sequence:
`exemption/cluster PR merged → CD applies to Wiz → tenant re-runs unikube.yaml`.
- New cluster: CD must create `container-scan-*-<cluster>` before any tenant targets it.
- New CVE exemption: the ignore rule must be applied before the re-scan, or the scan
  still fails. (unikube.yaml notes this; call it out in tenant docs.)

### C2. Exemptions are per-artifact, not per-cluster-differentiable
An exemption lives in `exemptions_build/<image>.yaml` and every admitting cluster
inherits it via the join, so an exemption for `my_image:1.0.0` applies to **all**
clusters that admit that exact image:tag. You cannot accept a CVE on dev but block
it on prod *for the same artifact* — the prod gate (Q1) controls whether the image
is admitted on prod at all, not a per-cluster CVE list. Acceptable (an accepted CVE
is a property of the artifact); documented so no one expects differentiation.

### C3. Multi-cluster scan cost (bounded, by design)
Per-policy attestation means a tenant image on N clusters needs N scans/tags —
handled by `unikube.yaml`'s `target_clusters` matrix. Platform images sidestep this
(DEPLOY ignore rules, no scan). Cost only hits tenant self-built images, typically
on 1–2 clusters.

## Recommended first implementation steps

1. **Wiz NONPROD spike:** hand-write one cluster's resources with the real provider,
   confirm item 1's schema, and adjust the engine module.
2. Wire the S3 backend + one real per-cluster state; run the matrix CI on a test PR.
3. Backfill SECRETS/MALWARE `property` (item 4).
4. Plan bootstrap + cluster-provisioning integration (item 5).
