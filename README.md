# Container Vulnerability Management — Architecture Decision Record

**Status:** Accepted · **Date:** 2026-08-04 · **Last amended:** 2026-08-25

This repository holds the design and implementation for container **admission** and
**vulnerability-exemption** management across the unikube EKS fleet (~200 clusters). This
README is the decision record.

> **ADR-0002 chose Wiz. ADR-0004 supersedes it: the control plane is Kyverno.**
>
> ADR-0002 is kept in full, unedited, because its two deciding rationales were never
> disproved — they were **outweighed**, and a record that quietly deletes the case against
> the current decision is worth nothing. Read ADR-0002 for what is being given up, then
> ADR-0004 for why.
>
> Two claims elsewhere in this record have been corrected against the Kyverno source and are
> marked inline (ADR-0002 rationale 3; ADR-0003 consequences) rather than edited away.

---

## 1. Goal

Every image reaching a cluster falls into one of three classes, and each gets exactly one
admission path:

| Image class | How it gets admitted | Human in the loop? |
|---|---|---|
| **Self-built, compliant** — built `FROM container-soe.registry.domain/*`, base fresh | **Automatically, by cryptographic signature.** CI signs it; the admission controller verifies. Admitted on every cluster. | **No.** This is the point — the fast path must be unattended, or nobody uses it. |
| **Self-built, non-compliant** — some `FROM` off the approved base, or a stale base | **Exemption only.** No signature is issued, so it is inert unless an approved exemption covers it on the target cluster. | Yes — security-approved PR, with a ticket, an approver, and an expiry. |
| **Vendor / OSS** — third-party images we do not build | **Exemption only.** Same mechanism, same review. | Yes — same as above. |

Two properties fall out of this and drive everything below:

1. **Compliance is proven, not asserted.** The compliant path must be unforgeable — a label
   saying `compliant=true` is attacker-controlled, so admission has to rest on a signature
   over the image digest.
2. **There is exactly one exemption mechanism**, shared by non-compliant self-built images
   and vendor/OSS images. Two mechanisms would mean two review paths, two audit trails, and
   two places for an exemption to be quietly forgotten.

Requirement 2 is the one that decides this ADR, and it is easy to lose sight of: the
problem is **vulnerability exemption management**, of which signature-based admission is
only the fast path.

---

## 2. Two decisions, not one

These are routinely conflated, and conflating them produces bad comparisons:

- **D1 — Signature format:** Notary v2 (Notation) or Sigstore (cosign)?
- **D2 — Control plane:** which system enforces admission and holds the exemptions — Wiz, or
  Kyverno?

They are **orthogonal**. Both Wiz and Kyverno verify both formats. Kyverno has had a native
`notary` attestor type — with its own documentation, not a workaround — for several
releases. So "we picked Notation" is not an argument for Wiz, and "we picked Wiz" does not
force Notation. Each decision has to stand on its own.

---

## ADR-0001 — Notary v2 (Notation) as the signature format

**Status:** Accepted

### Context

Signing must work from GitHub Actions runners that reach the internet only through a
**proxy allowlist**, and the organisation already operates an internal X.509 CA with
established key-custody practice (HSM/KMS).

### Options

| | Sigstore / cosign (keyless) | Notary v2 / Notation |
|---|---|---|
| Trust root | Fulcio CA + Rekor transparency log, OIDC identity | **Your** CA certificate |
| Runtime deps at sign time | OIDC provider **and** Fulcio must be reachable | None beyond the registry |
| Runtime deps at verify time | Rekor reachable, unless inclusion proofs are bundled offline | None |
| Fit with existing PKI | Parallel trust system | Uses the CA we already run |
| Self-hosting for restricted egress | Run Fulcio + Rekor yourself — a project in its own right | n/a |

### Decision

**Notation, signing with a certificate issued by the internal CA.**

### Rationale

- **Fewest new moving parts under our network posture.** Keyless signing fails if the OIDC
  provider or Fulcio is unreachable, and verification fails if Rekor is unreachable unless
  proofs are bundled. Behind a proxy allowlist that is a set of external dependencies on the
  build-and-admit path, each with its own outage mode. Notation's verification is a local
  chain-validation against a CA cert we hold.
- **It fits our key-custody model.** Notation's plugin model targets HSM/KMS directly, so the
  signing key never reaches a runner. Note this is *not* "we reuse the org CA" — see
  ADR-0003, which forced a standalone signing root. The org's HSM/KMS practice and audit
  expectations still apply; the certificate hierarchy does not.
- **Cert expiry gives coarse revocation for free.** We deliberately do **not** trust-timestamp
  signatures, so verification checks the leaf's validity window against *now* — meaning when
  the signing leaf expires, every image it signed stops being admissible. This is a blunt
  instrument and we accept it as one. Note the leaf is **365 days**, so the blunt instrument
  is now year-scale: a leaked leaf key stays usable until it expires. If that becomes the
  binding concern, the fix is real revocation (CRL/OCSP reachable from the Wiz admission
  controller — unverified) or a shorter leaf, not a change of signing format.

### Consequences

- We own the PKI: issuance, annual leaf rotation, and CA custody are ours to run — and per
  ADR-0003 that means a *separate* CA hierarchy, not the org's. Sigstore's main selling
  point — no long-lived keys to leak — is a real benefit we are giving up.
- No transparency log. There is no public, tamper-evident record of what was signed; the
  audit trail is the registry plus our own CI logs.
- **Not** an air-gap argument. Egress is restricted, not absent — a self-hosted Sigstore
  stack would be technically possible. We rejected it on cost and operational surface, not
  impossibility, and the ADR should not be read as claiming otherwise.

---

## ADR-0002 — Wiz as the admission and exemption control plane

**Status:** ~~Accepted~~ **SUPERSEDED by ADR-0004 (2026-08-25).** Kept in full and unedited.
Rationales 1 and 2 below are still true; they lost, they were not refuted. If you are about to
argue for going back to Wiz, this section is your case and it is a real one.

### Context

- **Wiz is already licensed and deployed**, and the security team already triages container
  vulnerabilities in it.
- **Kyverno is already running fleet-wide** for configuration policy (e.g. blocking pod
  exec). This is the significant fact in this decision and it cuts *against* Wiz: the usual
  "that's a whole new component to operate" objection to Kyverno does not apply here. Kyverno
  is installed, understood, and already in the admission path.
- ~200 clusters across two Wiz tenants; exemptions require security approval and must expire.

### Options

**Option A — Kyverno.** `ImageValidatingPolicy` / `verifyImages` with a `notary` attestor for
the compliant path; `PolicyException` CRDs for exemptions, delivered per cluster by GitOps.
Vulnerability scanning bolted on separately (Trivy or similar), with its own ignore list.

**Option B — Wiz.** Image Trust policy backed by a shared image-integrity validator holding
the CA cert; exemptions as Wiz ignore rules; vulnerability scanning already native.

### Decision

**Wiz**, with Kyverno retained for configuration policy. Terraform renders both from
reviewed YAML in this repo.

### Rationale (the arguments that survive scrutiny)

1. **One exemption mechanism instead of two — this is the deciding argument.** The goal is
   vulnerability exemption management. Kyverno does not scan for vulnerabilities, so Option A
   means a `PolicyException` for the admission question and a scanner ignore-rule for the
   vulnerability question — two objects, two review paths, two expiry mechanisms, two audit
   trails, for what a security reviewer experiences as one decision ("do we accept this
   image?"). Wiz collapses both into one ignore rule. Requirement 2 in §1 is not satisfiable
   under Option A without building the glue ourselves.
2. **Exemptions are central objects, not fan-out.** A `PolicyException` is a cluster-scoped
   CRD: an exemption must be replicated to each cluster it applies to, giving ~200 places to
   drift and ~200 places to audit "who is currently exempt from what". Wiz ignore rules are
   central to the tenant. We still fan out *Terraform* per cluster, but the record of truth
   is one API, not 200 etcds.
3. ~~**Expiry is a first-class field.**~~ **RETIRED 2026-08-18.** True of Kyverno v1.18.2,
   where nothing in the cluster retires an exemption: `spec.expiresAt` is declared on the CRD
   and ignored by the engine (kyverno#16299 landed after that release), and the composed
   `ClusterCleanupPolicy` + TTL-label pattern is no longer rendered — expiry there is enforced
   at render time only. **v1.19 adds
   `PolicyException.spec.expiresAt` and `spec.properties` (`reason`/`ticket`/`approved-by`),
   enforced by the engine** — so this rationale does not survive the version the fleet is
   moving to. It is left in place, struck through, because a rationale that quietly disappears
   is worse than one shown to have expired. Note also that the aggregation forced on the Wiz
   side by its ignore-rule cap means Wiz now has **no per-entry expiry at all** — the field is
   real, but there is one of it per scope. On this axis Kyverno v1.19 is ahead.
4. **It is where the security team already works.** The ignore rules are the same objects
   they already use for vulnerability triage; no second console, no reconciling "exempt in
   Kyverno" against "still open in Wiz".
5. **Marginal cost is near zero and the format door stays open.** Wiz is deployed and paid
   for, and it verifies Cosign as well as Notary — if ADR-0001 is ever revisited, the control
   plane does not have to change with it.

### Arguments considered and rejected

Recorded explicitly because they were raised, are intuitive, and are **wrong** — a reviewer
who knows Kyverno would otherwise assume the comparison was not done carefully:

| Claim | Verdict |
|---|---|
| "Kyverno doesn't natively support Notation, only Sigstore." | **False.** Kyverno has a documented native `notary` attestor. Signature format is not a differentiator between the two engines. |
| "Kyverno exemptions are configmaps, at the mercy of ArgoCD; if ArgoCD is down, exemptions stop working." | **False on both counts.** They are `PolicyException` CRDs, and once applied they live in etcd — Kyverno's webhook reads them from the API server. An ArgoCD outage blocks *new* exemptions from landing; it does not break enforcement of existing ones. The valid version of this concern is fan-out and drift (rationale 2), not availability. |
| "Notation works perfectly with Wiz." | **True but not load-bearing.** Wiz requires you to bring and maintain the Notary or Cosign infrastructure and keys either way; it verifies, it does not issue. |

### Consequences and accepted costs

- **Two admission webhooks in the path.** Kyverno (configuration) and Wiz (image trust) now
  both gate pod creation. Their failure policies, ordering and combined latency need to be
  understood together; a fail-closed Wiz webhook plus a fail-closed Kyverno webhook is two
  independent ways to stop all deployments.
- **Commercial dependency and lock-in** for a control that is now on the critical path to
  deploying anything. Kyverno's independence — free, CNCF, no vendor — is a genuine
  advantage we are giving up.
- **The cheaper option was left on the table.** Kyverno is already there; image verification
  would have been an incremental policy, not a new system. We are paying for the unified
  exemption model, and if that model does not materialise in practice, this decision was
  wrong.
- **Blast radius is concentrated.** One shared validator and one CA serve both tenants and
  every platform, so trust-root changes are fleet-wide events. See
  [`container-vulnerability-exemption/trust/README.md`](container-vulnerability-exemption/trust/README.md).

### Open risks

1. **Wiz admission controller behaviour when the Wiz backend is unreachable** — fail-open or
   fail-closed, and whether policy is cached — is **not yet verified**, and matters more than
   usual given the proxy-allowlist egress. This is the single most important thing to confirm
   before enforcement moves from AUDIT to BLOCK.
2. **CA rotation has no overlap window.** The validator holds one trust anchor and one CA
   serves both tenants, so replacing it is a hard cutover. A concatenated PEM bundle is the
   usual mitigation but is unverified against the Wiz provider.
3. **The `wiz-v2` Terraform provider is internal/blackbox** and the modules have not been run
   against a live provider.

### Revisit triggers

Reopen this decision if any of these become true:

- Kyverno gains a first-class vulnerability-exemption model that unifies the two questions
  (this would remove rationale 1, the deciding argument).
- Wiz commercial terms change materially, or Wiz ceases to be the security team's triage tool.
- The dual-webhook arrangement causes a production admission outage.
- Risk 1 resolves badly — i.e. a Wiz backend outage can block deployments fleet-wide with no
  cached-policy fallback.
- Wiz adds signer-identity pinning to `image_integrity_validator` (see ADR-0003 — this would
  let us fold the signing CA back under the org root and retire a whole PKI).

---

## ADR-0003 — A standalone signing CA, three tiers

**Status:** Accepted · Consequence of ADR-0002

### Context

The organisation runs an internal root CA, and the obvious move was to sign images with a
certificate issued by it. That turns out to be unsafe **given the enforcement point we chose
in ADR-0002**.

`wiz-v2_image_integrity_validator` exposes exactly one field: `certificate`. It is a trust
store and nothing else — there is no equivalent of Notary's `trustedIdentities`, which is the
mechanism that would let us trust a broad CA while restricting *which signer* under it counts.

Without that, a CA is not an authorization boundary. Trusting the org root would mean
trusting every certificate the organisation issues: any team with an org-issued cert could
sign an image and have it admitted on all ~200 clusters, unattended, in both tenants.

### Options

**A — org root in the trust store.** Rejected: fleet-wide privilege escalation, as above.
Would be the best option *if* Wiz supported identity pinning, which is why that is now a
revisit trigger on ADR-0002.

**B1 — a dedicated intermediate under the org root, placed in the trust store.** Keeps org
key custody. Rejected on two grounds: the Notary spec advises against intermediates as trust
anchors because *"[it] is a form of certificate pinning that can break signature verification
unexpectedly anytime the intermediate certificate is rotated"*, and that intermediate would
rotate on the org PKI's schedule, making a fleet-wide cutover something another team triggers.

**B2 — a standalone signing root, used only for image signing.** Chosen.

### Decision

A **standalone three-tier PKI**: offline root (10y) → issuing intermediate (5y) → signing
leaf (~365d). The **root** is the trust anchor in `trust/ca.crt`; the intermediate does
day-to-day issuance; only the leaf is short-lived and reaches CI.

Three tiers specifically because the trust store is the *only* lever Wiz gives us, so the
anchor must be stable. Leaf and intermediate rotation both leave `trust/ca.crt` untouched —
no Wiz change, no terraform apply, nothing already signed invalidated. Only root replacement
is a hard cutover, and roots last a decade.

### Consequences

- **A second PKI to run.** Issuance, rotation and root custody are ours. It needs the
  security/PKI team's sign-off as an approved internal CA even though it does not chain to
  theirs. This weakens — but does not overturn — ADR-0001's key-custody rationale: we still
  use the org's HSM/KMS practice, just not its certificate hierarchy.
- **The root key is the crown jewel.** Whoever holds it can mint an intermediate and admit
  anything, anywhere, in both tenants. Offline, HSM-backed, from day one.
  `gen_signing_certs.sh` generates keys on disk and is test material only.
- **Signatures must carry the complete chain** (leaf → intermediate → root); a bare leaf
  signs successfully and then fails verification at admission. `sign-image.sh` refuses one.
- **DN discipline is kept regardless** (`C`, `ST`, `O`, `OU` on every leaf). It makes local
  `notation verify` a real check, and it is a prerequisite for the one revisit path that
  remains: Wiz adding pinning.

  > ⚠ **CORRECTED 2026-08-18.** This bullet used to say DN discipline was a prerequisite for
  > "both revisit paths — Wiz adding pinning, or a move to Kyverno, **which supports it
  > today**". That was **false**, and it mattered: it made Kyverno look like an escape hatch
  > from this ADR's central problem. Kyverno builds the Notation trust policy in Go and
  > hardcodes `TrustedIdentities: ["*"]` (`pkg/image/verifiers/ivpol/notary/helpers.go`, and
  > identically for legacy `verifyImages`); the CRD's `notary` attestor exposes exactly two
  > knobs, `certs` and `tsaCerts`. **Neither engine can pin a signer identity.** On both, the
  > trust store is the only authorization boundary — which makes this ADR's standalone signing
  > root necessary rather than merely tidy. Verified against `v1.18.2` and `main@1df9235`.

---

## ADR-0004 — Kyverno as the admission and exemption control plane

**Status:** Accepted · **Date:** 2026-08-25 · **Supersedes:** ADR-0002

### Context

ADR-0002 chose Wiz and both backends were then built, so the comparison is no longer between
a running system and a design. Two things changed the weighting:

- **The unified-exemption argument turned out to be narrower than it reads.** Rationale 1 says
  one ignore rule answers both "may this image be admitted" and "do we accept this CVE". True
  — but the population it unifies is the *exempted* one, and the fast path (a signed, compliant
  build) never touches an exemption at all. The unification is real for the minority case.
- **Kyverno was already in the admission path** for configuration policy. Choosing Wiz meant
  running two admission webhooks, each with its own failure policy, ordering and latency, and
  two independent ways to stop every deployment in the fleet. That cost was recorded in
  ADR-0002's consequences and it did not get smaller.

### Decision

**Kyverno**, in **AUDIT** mode fleet-wide to begin with. One `ImageValidatingPolicy` and one
`PolicyException` per exemption, rendered per cluster from the same reviewed YAML.

### Rationale

1. **One webhook, not two.** The dual-webhook arrangement was ADR-0002's first accepted cost
   and it is removed rather than mitigated.
2. **No commercial dependency on the deploy path.** ADR-0002 recorded "we are giving up
   Kyverno's independence" as a genuine loss. We are taking it back.
3. **Per-entry exemption metadata is honest again.** Wiz caps ignore rules per tenant, so every
   exemption in a scope aggregates into ONE rule carrying ONE operator and ONE expiry — which
   is why `expired_at`, `operator: equals` and `namespaces` were *rejected by validate.py* on
   this tree. Under Kyverno each entry is its own object, and all three become real fields.
   Two approvals in this repo were being applied more broadly than review granted them
   (a vendor image approved for two namespaces, an exemption approved until a date) purely
   because the fields could not be written down. That is a security improvement, not tidying.
4. **AUDIT mode gives an exemption-usage trail that BLOCK cannot.** Measured: under `[Audit]`
   an exempted workload produces a `skip` row naming the exception. Under `[Deny, Audit]` that
   row disappears — once Deny is present, results that do not deny are not reported at all. So
   the mode we are starting in is the only one in which a stale exemption and a load-bearing
   one are distinguishable. Collect that data before anyone proposes flipping to BLOCK.

### What is being given up, in full

ADR-0002's rationales 1 and 2 are **not refuted by this decision** and are the honest cost:

- **Two exemption mechanisms, not one.** Kyverno does not scan. A `PolicyException` answers
  "may this image be admitted" and never "do we accept this CVE". The vulnerability half needs
  its own ignore list, its own review path and its own expiry, and nothing here builds that
  glue. **This is the argument that would reverse this decision if it is felt in practice.**
- **Fan-out to ~200 etcds.** There is no object shared between clusters, so an env-wide
  exemption is copied into every cluster in the env and a trust-anchor rotation is a diff in
  every cluster directory. `kyverno_render.py --summary` prints the multiplier on every render
  rather than leaving it as a claim.
- **No central record of what is permitted.** Reading `PolicyException` objects across 200
  clusters replaces one tenant API query.

### Consequences

- **AUDIT is a measurement programme, not a control.** Nothing is denied. The deliverable of
  this phase is a defensible number for the unsigned-image population, and phase 1's known
  hole biases it: a pod carrying an exemption yields one `skip` row and its other images are
  never evaluated (see [`container-vulnerability-exemption/unikube/README.md`](container-vulnerability-exemption/unikube/README.md)).
- **`failurePolicy` is a separate danger from `enforcement`.** `Fail` blocks pod creation
  cluster-wide even on an AUDIT cluster. Default is `Ignore`, and the cost of `Ignore` is that
  a registry 401 is an evaluation error, so the policy is skipped and no report row is written
  — a broken credential config looks exactly like a clean fleet. The compensating control is
  `kyverno_image_validating_policy_results`, not the reports.
- **The trust anchor is now inlined into every cluster's policy** rather than held once by a
  shared validator, and multi-anchor rotation is **unverified** against Kyverno. Confirm it
  before planning a rotation; the fallback is one attestor per anchor.
- **Neither engine can pin a signer identity** (see the correction in ADR-0003), so the
  standalone signing root remains necessary. It was not a Wiz artefact.

### Revisit triggers

- The two-mechanism cost above is felt in practice — exemptions drifting between the admission
  list and the scanner's ignore list, or a CVE accepted in one and not the other.
- Kyverno's `PolicyException` remains resource-scoped for `ImageValidatingPolicy` long enough
  that phase 2's residual hole matters. Filed upstream; see
  [`project_metadata/kyverno-issue.md`](project_metadata/kyverno-issue.md).
- A Kyverno outage blocks deployments fleet-wide (i.e. `failurePolicy` was set to `Fail`
  somewhere, or the webhook's latency became load-bearing).

---

## 3. Side-by-side summary

Kept because ADR-0002 is kept: this is what the decision traded away.

| | **Kyverno + Notation** (chosen, ADR-0004) | Wiz + Notation (ADR-0002, superseded) |
|---|---|---|
| Signature formats | Notary **and** Cosign, both native | Notary **and** Cosign, both native |
| Signer-identity pinning | **No** — `TrustedIdentities: ["*"]`, hardcoded | **No** — one `certificate` field |
| Vulnerability scanning | Not included — bolt on Trivy or similar | Native |
| Exemption object | `PolicyException` CRD, per cluster | Ignore rule, central per tenant |
| Exemption granularity | One object per entry: per-entry operator, expiry, namespaces | Whole scope aggregates into ONE rule: one operator, one expiry, no namespaces |
| Exemption expiry | Native `spec.expiresAt` on 1.19; **render-time only on 1.18** | Native field, but one per scope |
| Exemptions for *vuln findings* | **Separate system entirely** | Same object |
| Exemption-usage trail | `skip` rows — **under AUDIT only** | The ignore-rule list, in either mode |
| Webhooks in the admission path | **One** (Kyverno was already there) | Two |
| Audit surface | ~200 etcds | One tenant API |
| Cost / lock-in | Free, CNCF | Commercial, already paid |

The honest reading, unchanged from when it was written the other way round: **Kyverno wins on
cost, independence and incumbency; Wiz wins on unifying the exemption model.** ADR-0002
weighted the exemption model higher; ADR-0004 weights the single webhook and the commercial
independence higher, having seen both built. Neither was a walkover.

---

## 4. What was built

- [`container-vulnerability-exemption/`](container-vulnerability-exemption/README.md) — the
  interface. The only repo tenants edit, and the only place an exemption is written.
- [`container-vulnerability-exemption.kyverno/`](container-vulnerability-exemption.kyverno/README.md)
  — the rendered manifests. Nothing here is hand-written; CI fails if the committed tree is not
  exactly what the exemptions tree renders to.
- [`project_metadata/project_summary.md`](project_metadata/project_summary.md) — current-state
  entry point.
- [`project_metadata/history/`](project_metadata/history/) — **archive.** The Wiz backend, the
  model comparison that preceded ADR-0004, and the design notes behind both. It answers almost
  every "why is it like this" question and it describes a repo that no longer exists. Do not
  read it to learn the current state.

### Two phases

**Phase 1 (shipped, every fleet cluster).** One `ImageValidatingPolicy` globbing `"**"`: every
image must carry a signature, or the pod must carry a `PolicyException`. It has one sharp
limitation, stated in the header of every generated file — a `PolicyException` skips a policy
for the whole **resource**, and there is exactly one policy, so exempting one image stops
verification of every image beside it in the same pod.

**Phase 2 (designed, one POC cluster, not yet rendered).** An `ImageValidatingPolicy` scoped to
the self-built prefixes, plus a **`ValidatingPolicy`** denying everything else by default. The
second half is a `ValidatingPolicy` on purpose and it is the whole reason the phase works: the
`exceptions` CEL variable — `PolicyException.spec.images`, read back as
`exceptions.allowedImages` — is registered for `ValidatingPolicy` and is **not** registered for
`ImageValidatingPolicy`. Measured: the ivpol expression fails to compile. So only the vpol half
can carry per-image exceptions. Phase 2 requires Kyverno 1.19 and is refused on 1.18.

Phase is per cluster (`admission.phase`), defaulted per env, exactly like the version pin.

## Sources

- [Notary | Kyverno](https://kyverno.io/docs/policy-types/cluster-policy/verify-images/notary/)
- [ImageValidatingPolicy | Kyverno](https://kyverno.io/docs/policy-types/image-validating-policy/)
- [Policy Exceptions | Kyverno](https://kyverno.io/docs/guides/exceptions/)
- [Expiration for PolicyExceptions | Kyverno](https://kyverno.io/policies/other/expiration-for-policyexceptions/expiration-for-policyexceptions/)
- [Temporary policy exceptions in Kubernetes with Kyverno | CNCF](https://www.cncf.io/blog/2023/03/01/temporary-policy-exceptions-in-kubernetes-with-kyverno/)
- [Ensuring Supply Chain Security: Verify container image integrity with the Wiz Admission Controller | Wiz](https://www.wiz.io/blog/ensuring-supply-chain-security-verify-container-image-integrity-with-the-wiz-admi) — for ADR-0002, which ADR-0004 supersedes
- [Sailing Securely Across the SDLC: Introducing Wiz's Image Trust | Wiz](https://www.wiz.io/blog/sailing-securely-across-the-sdlc-introducing-wiz-s-image-trust-and-kubernetes-aud) — for ADR-0002, which ADR-0004 supersedes
- [Sigstore Keyless Signing and Cosign Verification: Fulcio, Rekor, and Policy Enforcement](https://www.systemshardening.com/articles/cicd/sigstore-keyless-signing/)
- [Scaling Up Supply Chain Security: Implementing Sigstore | OpenSSF](https://openssf.org/blog/2024/02/16/scaling-up-supply-chain-security-implementing-sigstore-for-seamless-container-image-signing/)
