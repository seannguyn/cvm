# Design Brainstorm — Container Vulnerability Management

Reacting to `1_project_brainstorm.md`. (`out/` is gitignored — ignored here.)

**Model (confirmed):** each cluster owns its **own** policy set — `container-scan-{vulnerability,secrets,malware}-<cluster>` plus its own `IMAGE_INTEGRITY` policy — generated from a golden **template**. There is **no shared default policy applied across clusters**. The golden "default" is a template/module in code, not a live Wiz policy that clusters point at.

## 1. Why per-cluster gives you *full* isolation (the reason, stated cleanly)

The attestation is what admission checks, and under this model the attestation is **cluster-scoped**.

- Build: image is scanned against `container-scan-vulnerability-<cluster>` and `wiz tag` records "image X passed **that cluster's** policy."
- Deploy: `tenant_Y_k8s`'s `IMAGE_INTEGRITY` validator (`*` → `container-scan-vulnerability-tenant_Y_k8s`, `fail_untested_image=true`) admits an image only if it holds an attestation for **`...-tenant_Y_k8s`**.

Consequence: an image scanned/tagged for `tenant_Y_k8s` has **no attestation** for `container-scan-vulnerability-tenant_Z_k8s`, so on `tenant_Z_k8s` it reads as untested → blocked. This holds for **every** image, not just exempted ones.

This is strictly stronger than a shared-default design, and it's the reason to choose per-cluster:

- **Shared default** only scopes *exemptions* per cluster; a *clean* image, once it passes `-default`, deploys anywhere.
- **Per-cluster** scopes *admission itself* per cluster. An image runs only where it was explicitly scanned and tagged. Both clean-image-sprawl and exemption-leakage are closed by the same mechanism.

That's the win. It also means the build↔deploy binding is automatically consistent: build and deploy both key on the same `<cluster>` policy id, so there's no "scanned against a different policy than the validator checks" gap. **Provided** the build workflow scans against the *target cluster's* policies (see §3).

## 2. The cost you're taking on — and where it bites

Per-cluster isolation isn't free. The price is multiplicity, and it concentrates in one place: **images that legitimately run on many clusters.**

- **Policy multiplicity.** 200 clusters × 3 build policies = ~600 `cicd_scan_policy` + 200 `IMAGE_INTEGRITY` + validators + ignore rules. All must be templated, named, stated, and planned reliably. This is a Terraform-scale problem, not a correctness problem (see §5).
- **Attestation multiplicity — the real pain.** Because admission is cluster-scoped, an image that runs on N clusters needs N scans and N `wiz tag` attestations against N different policies. For a **tenant** image pinned to its own 1–2 clusters, fine. For **platform / shared images** (EBS CSI driver, cert-manager, velero, ArgoCD) that run on *all* 200 clusters, "scan and tag 200 times per release" is untenable.

So the decision to drop the shared default relocates the hard problem from *isolation* to *how shared images cross all clusters*. That's the thing to solve next.

## 3. Platform & common-vendor images — the new central question

Options, roughly in order of how much I'd lean toward them:

1. **Tiered validators per cluster.** Each cluster's `IMAGE_INTEGRITY` policy carries *ordered* validators:
   - specific `image_patterns` for platform/vendor images → a **shared platform baseline** policy (`container-scan-vulnerability-platform`), scanned/tagged **once** per image release;
   - `image_patterns=*` catch-all → the **cluster-specific** policy for tenant images.
   This keeps full per-cluster isolation for tenant workloads while letting platform images cross all clusters with one attestation. Note this reintroduces *one* shared policy — but only for platform-owned images, which is a controlled set. Worth confirming that "no shared default" means "for tenant images"; a platform baseline is almost certainly needed.
2. **Vendor/opensource via ignore rules only.** These have no build phase and no attestation; they're admitted by each cluster's `IMAGE_INTEGRITY` `ignore_rules`. Under option 1 you'd instead reference them by `image_patterns` against the shared platform policy where sensible, and reserve ignore rules for genuine one-off risk acceptance.
3. **Scan-fan-out (brute force).** Reusable workflow scans platform images against every target cluster's policy. Rejected unless the platform image set is tiny — it's 200× work and 200 attestations to keep fresh.

**Recommendation:** two tiers — a shared **platform baseline** policy for platform-owned/common-vendor images (option 1), plus fully per-cluster policies for tenant images. Decide this before schema, because it changes what `exemptions_deploy/*/global.yaml` and the per-cluster files must express.

## 4. Build must know its deploy target(s)

Direct consequence of §1: the reusable build workflow can no longer scan against a single default. Its inputs must include **target cluster(s)**, and it scans + tags the image against each target's policies. Design questions:

- What's the input shape — a list of `AWS_ACCOUNT_ID_CLUSTER_NAME`? Does it read the `exemptions_deploy` tree to resolve which policy ids to scan against?
- Multi-cluster tenant images: N scans, accept it, but cap N (a tenant image on 50 clusters is a smell — that's probably a platform image and belongs to the shared baseline in §3).
- Platform images: routed to the shared baseline scan, once.

## 5. Terraform state & blast radius (now clearly per-cluster)

Per-cluster policies map naturally to **per-cluster state** — state key = `AWS_ACCOUNT_ID_CLUSTER_NAME`. Benefits: blast radius is one cluster; CI can plan only the states whose YAML changed in the PR (no re-planning 600 policies per PR). Backend S3 + DynamoDB lock; local state fine for dev. A shared platform baseline (§3) gets its own separate state.

## 6. Golden template = code, and its version rollout

Since "golden default" is a **template** that instantiates 200 cluster policy sets, a template change regenerates all 200. So:

- Pin the template/module version (`container-vulnerability-exemption.tf:vX.Y.Z`) **per env** so you can canary `ga-nonp` before `ga-prod`.
- A baseline threshold change is a **fleet-wide apply** — needs staged rollout + soak, not big-bang.
- Decide: is the version pinned per-env, or per-cluster (lets you canary a single cluster)?

## 7. Lifecycle & hygiene (unchanged, still matters)

- **Expiry on every exemption/ignore rule** (`expires_at`); CI fails/warns on expired → forces re-review. Extend the `max_age` discipline you already have on validators.
- **Decommission:** cluster deleted → its YAML removed → `tf destroy` its policy set. Verify no orphaned Wiz resources.
- **Drift:** scheduled `tf plan` to catch console edits.

## 8. Governance (unchanged)

- CODEOWNERS: security owns the template and any shared platform baseline; tenants own only their `exemptions_build/<image>.yaml` and their cluster file.
- Security-team approval as branch protection on exemption PRs.
- Documented break-glass with mandatory post-hoc review.

## 9. Schema is the product (unchanged)

Write JSON Schemas for each file type, validate in CI **before** `tf plan`, version the schema with the module. This is what makes "limited interface" real.

## 10. Tag vs digest (unchanged, important)

Pin exemptions and `wiz tag` attestations to **image digest** `@sha256:...`, not mutable tags; prefer **per-CVE** ignore rules over whole-image ignores. Enforce in schema.

## Open questions to resolve next

1. Does "no shared default" mean *for tenant images only*, i.e. is a shared **platform baseline** policy acceptable for platform/common-vendor images (§3)? This is the pivotal one.
2. Reusable build workflow: how are target cluster(s) supplied, and does it resolve policy ids from the `exemptions_deploy` tree (§4)?
3. State granularity: per-cluster confirmed? (§5)
4. Template version pinning: per-env or per-cluster (§6)?
5. Mandatory expiry on exemptions (§7)?
6. Digest-pinning required (§10)?

## Suggested build order

1. Decide §3 (platform baseline vs pure per-cluster). Everything downstream depends on it.
2. Lock YAML **schemas** + example files for each file type.
3. Build the **`.tf` module** for one cluster's policy set against a dev Wiz tenant, local state.
4. Wire **CI** (schema validate → selective per-cluster `tf plan`).
5. Wire **CD** (`tf apply`, S3 state, per-cluster keys, staged template rollout).
6. Author the **reusable build workflow** (target-cluster input → scan → tag → push).
7. Add **lifecycle**: expiry checks, decommission destroy, drift detection.
