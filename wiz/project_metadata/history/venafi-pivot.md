# Pivoting the signing PKI to Venafi — a possibility writeup

**Status: analysis only. Nothing in the repo has been changed by this document.**

Context: the org runs **Venafi Control Plane (SaaS)** — now branded CyberArk Machine Identity
Security — and owns an org root CA. Today this repo's trust anchor is a *self-signed test root*
produced by `unikube/scripts/gen_signing_certs.sh`, sitting in
[`../container-vulnerability-exemption/trust/ca.crt`](../container-vulnerability-exemption/trust/ca.crt),
with the leaf key delivered to CI as a PEM string in an env var. Both are placeholders that
[`trust/README.md`](../container-vulnerability-exemption/trust/README.md) and
[`notation-signing.md`](notation-signing.md) already flag as
"replace before production".

This document answers two questions:

1. What does Venafi actually buy us, and where does it plug in?
2. **Dedicated Venafi-managed signing root** vs **the existing org root** as the Wiz trust
   anchor — which, and why?

**Verdict up front:** Venafi is a clear win on *issuance, key custody and audit*, and should be
adopted. It is **not** a reason to move the trust anchor to the org root. The recommendation is
**Option A — a dedicated container-signing root hosted and HSM-backed by Venafi**, which keeps
every security property of the current design and replaces the parts that were only ever test
scaffolding. See [§5](#5-side-by-side).

---

## 1. The one sentence the whole decision hangs on

Unchanged from [`notation-signing.md` §3](notation-signing.md):

> **`wiz-v2_image_integrity_validator` accepts exactly one field: `certificate`.**
> No signer-identity pinning, no trusted-identities list, no certificate bundle.

Venafi does not change this. Venafi is an *issuance and custody* control plane; the Wiz
validator is the *verification* gate, and it will keep seeing exactly one CA certificate no
matter how sophisticated the PKI behind it becomes.

That split is the recurring theme below. **Every Venafi control is enforced at issuance time by
Venafi. The Wiz gate enforces one thing: "does this chain terminate in the certificate in
`trust/ca.crt`?"** A control that lives on the issuance plane cannot narrow what the
verification plane will accept.

---

## 2. What Venafi Control Plane gives us

### 2.1 Verified from vendor documentation

| Capability | What it is | What it replaces here |
|---|---|---|
| **Zero Touch PKI (ZTPKI)** | Private-PKI-as-a-service. Venafi *"creates and integrates root and intermediate CAs and maps them to an organization's needs"*, with *"hardware-based root and intermediate key storage"* on a FIPS 140-2 HSM. | `gen_signing_certs.sh` — a bash script generating a root key **on a laptop's filesystem** |
| **Code Sign Manager, SaaS** (formerly CodeSign Protect) | Code-signing key custody + signing-as-a-service. Keys stay in the HSM; the signing operation is remote. Adds per-signature approval policy and an audit record. | `NOTATION_SIGNING_KEY` as a GitHub secret — a private key materialised on a runner's disk |
| **`notation-venafi-csp` plugin** | Official Notary Project plugin. Badged compatible with **Code Sign Manager SaaS** and self-hosted 23.1+. Supports RSA-2048/3072/4096 and EC-256/384/521, COSE + JWS, `signingScheme: notary.x509`. | The whole `notation key add` / `signingkeys.json` merge dance in `sign-image.sh` (~60 lines of the trickiest code in the repo, incl. the macOS config-dir workaround) |
| **Issuing templates / request policies** | Constrain what certificates an application may request — subject DN, key type, validity, EKU. | The `clamp_to_issuer()` / `--allow-short` logic, and the DN discipline currently enforced only by convention in a shell script |

Three of those replace things the repo itself labels as scaffolding. That is the strongest
argument for the pivot and it is largely independent of the anchor question.

### 2.2 Not verified — confirm with your Venafi SE before committing

- **Does ZTPKI issue certificates on the Notary *code-signing leaf profile*?** ZTPKI's documented
  ecosystem (SCEP, EST, ACME, Intune, Jamf, AD auto-enrolment) is TLS/device-identity shaped.
  The leaf profile Notation requires is narrow: `basicConstraints CA:FALSE`,
  `keyUsage digitalSignature` **without** `keyCertSign`/`cRLSign`, EKU that may contain
  `codeSigning` and **must not** contain `serverAuth`, `clientAuth`, `timeStamping` or
  `anyExtendedKeyUsage`. Code Sign Manager is the product actually aimed at this; whether the
  CA behind it can be a ZTPKI hierarchy, or is its own, is the first thing to establish.
- **Can we get a *dedicated* hierarchy** — our own root, used for nothing else — rather than a
  shared or tenant-wide one? ZTPKI is described as building hierarchies "mapped to an
  organization's needs", which reads as yes, but "dedicated to one use case" is a procurement
  and PKI-policy question, not just a product one.
- **Does `notary_v2.certificate` accept a concatenated PEM bundle?** Still open
  ([`notation-signing.md` §8 Q2](notation-signing.md)), and it is what decides whether the
  cutover in [§6](#6-what-the-cutover-actually-touches) can have an overlap window.

### 2.3 Two traps

**Do not enable timestamping.** Code Sign Manager ships a Code Signing Timestamp Service, and
it is normally considered best practice. **Here it would silently destroy our only revocation
mechanism.** Per [`notation-signing.md` §1](notation-signing.md), we deliberately do not
trust-timestamp: with no TSA, certificate expiry bounds the damage from a leaked key, and an
attacker cannot extend it. A timestamped signature survives certificate expiry indefinitely.
Whoever configures the CSM project must switch this off explicitly and it should be a documented
assertion, not an assumption.

**Approval workflows must be set to non-interactive for CI.** CSM's per-signature approval is a
genuine control, but a human gate on every build inverts the whole "compliant image is admitted
with no PR" model in `new_direction_PLAN.md`. The signing project needs an auto-approve policy
scoped to the pipeline's service identity, with the audit record as the compensating control.

**And a connectivity note:** signing-as-a-service means the **build runner** needs egress to the
Venafi SaaS control plane. Verification does not — Wiz still verifies offline from the embedded
certificate — so the air-gapped-CA reasoning that chose Notary over cosign is unaffected. But if
build runners sit behind a restrictive proxy allowlist, that is a prerequisite, and it makes
Venafi a **new hard dependency of the build path**: if the control plane is unreachable, nothing
gets signed, and nothing unsigned gets admitted.

---

## 3. Option A — dedicated container-signing root, Venafi-managed

```
Container Signing Root CA          Venafi HSM, dedicated    -> trust/ca.crt, into Wiz
  └─ Unikube Image Signing CA      Venafi HSM               -> travels in the chain
       └─ unikube-image-signer     Code Sign Manager        -> signs; key never leaves HSM
```

Structurally **identical to the current design**. What changes is provenance and custody, not
topology:

| | Today | Option A |
|---|---|---|
| root key | openssl, on disk, in `out/pki/` | Venafi HSM, FIPS 140-2, never extractable |
| intermediate key | same | Venafi HSM |
| leaf key | PEM string in a GitHub secret, written to a runner tmpdir | **never leaves the HSM**; runner holds only a token |
| issuance | `gen_signing_certs.sh` on someone's laptop | Venafi issuing template, policy-enforced, logged |
| rotation | a human remembering, plus the script's clamp | scheduled + policy-clamped validity |
| audit | git history of `trust/ca.crt` | git history **plus** a signed record of every signing operation |
| `trust/ca.crt` | test root | real root |
| Wiz's view | one CA cert | **one CA cert — unchanged** |

**The invariant survives:** *"chains to this root" and "signed by our pipeline" remain the same
statement*, enforced by key custody. That is the property `trust/README.md` was built around, and
it is the only thing standing in for the `trustedIdentities` check Wiz does not implement.

**Cost:** it is still a second PKI. The org PKI team must sign it off as an approved internal CA
even though it does not chain to theirs — exactly the objection `trust/README.md` already
records under *"What we give up"*. Venafi materially softens this: it is no longer "a shadow PKI
the platform team runs with openssl", it is "another hierarchy in the same governed control
plane, with the same HSM, the same audit, and the same lifecycle tooling as everything else the
PKI team owns". That reframing is most of the sign-off argument.

---

## 4. Option B — the existing org root as the anchor

Putting the org root PEM into `trust/ca.crt`, and issuing our signing certs from an org
intermediate under it.

**The appeal is real** and worth stating fairly: one PKI, one governance process, no exception to
argue for, no second root to defend at audit, and the org root's rotation is already somebody's
funded job. If the security question below can be answered, this is the cheaper long-term
operating model.

### 4.1 What actually breaks

`trust/README.md` states the objection as *"any team with an org-issued cert could sign an image
and have it admitted on all ~200 clusters"*. **That is slightly too strong, and the precise
version matters**, because the imprecision is what will get the argument dismissed in a review:

Notation enforces the leaf certificate profile at verification. An ordinary org **TLS server
certificate cannot be used to sign an image** — `serverAuth` in the EKU fails the profile, as
does a CA certificate (`CA:TRUE`). So the exposure is not "every certificate the organisation
issues".

The accurate statement is narrower and still disqualifying:

> **Any certificate issued anywhere under the org root that meets the Notary code-signing leaf
> profile can sign an image that Wiz will admit on every cluster in both tenants.**

Which is precisely the population Venafi Code Sign Manager exists to grow. Adopt CSM org-wide —
the obvious next step for any org buying it — and every code-signing certificate in the company
becomes a fleet-wide container-admission credential. The control that would prevent this is
`trustedIdentities`, pinning `OU=Platform-Unikube`. **Wiz does not implement it.**

### 4.2 Can Venafi policy compensate?

This is the strongest counter-argument to Option A and deserves a straight answer: **partially,
and on the wrong plane.**

| Proposed control | Why it is not sufficient |
|---|---|
| Issuing template restricts `codeSigning` EKU to the unikube application | Enforced by Venafi at *issuance*. Wiz enforces nothing at *verification*. A policy change, a second CSM project, an org acquisition, or a migration to a different Venafi tenant silently widens what the gate accepts — **with no signal at the gate, no diff in this repo, and no CODEOWNERS review**. |
| Dedicated org intermediate, placed directly in the Wiz trust store | Rejected by the Notary spec: *"placing intermediate certificates in the trust store is not recommended as this is a form of certificate pinning that can break signature verification unexpectedly anytime the intermediate certificate is rotated"* — and that intermediate would rotate on the org PKI's schedule, taking the fleet with it. |
| Approval workflow on the signing project | Same plane problem, and it does not constrain *other* projects under the same root. |

The structural point: today, widening fleet-wide admission authority requires a PR to
`/trust/` with `@org/security-leads` approval. Under Option B it requires a Venafi
administrator to create a project — a routine action, by a different team, invisible to this
repo. **Option B converts a reviewed, versioned security boundary into a configuration setting in
another system.**

### 4.3 The calendar problem

Image admissibility is `min()` over the *whole* chain, including the root
([`notation-signing.md` §5](notation-signing.md)). Under Option B, the org root's `notAfter` is a
term in that expression:

- If the org root is rotated or re-keyed, **every signed image in both tenants becomes
  unadmissible** at that moment, on the org PKI's schedule, not ours.
- The "replace the root by ~year 5 of its 10-year life so it can still issue a full-length
  intermediate" arithmetic now belongs to a team that has no reason to know container
  admissibility depends on it.
- Our leaf and intermediate validities get clamped by whatever the org intermediate has left.
  `gen_signing_certs.sh`'s clamp exists precisely because this failure is *silent*: the leaf
  still reads 365 days while the images die sooner. That check would need reimplementing against
  Venafi-issued certs regardless of which option is chosen — under Option B it is load-bearing.

### 4.4 The one genuine advantage of Option B

Org roots typically carry **CDP and AIA extensions**, so CRL/OCSP revocation is real. Ours carry
neither, which makes Notation's validation 5 a no-op that always passes
([`notation-signing.md` §2](notation-signing.md)) and leaves certificate expiry as our only
revocation lever — up to 365 days for a leaked leaf.

Under Option B a compromised signing key could be revoked in hours rather than aged out over a
year. That is a serious gain, and it is the argument to take seriously.

**But it is conditional on** Wiz's admission controller reaching CRL/OCSP endpoints through the
proxy allowlist — [`notation-signing.md` §8 Q5](notation-signing.md), still unanswered — and on
Wiz enforcing revocation at `strict`, which we cannot inspect. If those hold, the right move is
**not** Option B: it is to put CDP/AIA extensions on the *dedicated* Venafi root's issuance
profile and get real revocation without giving up the authorization boundary. Venafi can host
CRL/OCSP for a private hierarchy. **This is the single highest-value question to put to the
Venafi SE**, because it removes Option B's only structural advantage.

---

## 5. Side by side

| | **A — dedicated root, Venafi-managed** | **B — existing org root** |
|---|---|---|
| Who can admit an image fleet-wide | our pipeline, by key custody | anyone holding an org code-signing cert |
| Boundary enforced by | HSM custody + `/trust/` CODEOWNERS | Venafi issuance policy, in another system |
| Changing that boundary requires | a security-approved PR in this repo | a Venafi admin action, invisible here |
| Root rotation schedule | ours | the org's |
| Blast radius of an org PKI event | none | every image, both tenants |
| Revocation | expiry only, unless we add CDP/AIA (we can) | CRL/OCSP, *if* Wiz can reach it |
| PKI-team sign-off needed | yes — a second approved internal CA | no |
| Wiz-facing design changes | **none** | none |
| Verdict | **recommended** | only if Wiz gains identity pinning, or enforcement moves to Kyverno |

The revisit trigger is explicit and already written down: if `wiz-v2_image_integrity_validator`
ever gains a `trustedIdentities` equivalent, **Option B becomes correct** and this second PKI
should be retired. Kyverno — the empty sibling directory at repo root — supports
`trustedIdentities` today. If enforcement ever moves there, re-open this.

---

## 6. What the cutover actually touches

Under Option A. Listed for scoping; **none of this has been done.**

| File | Change | Impact |
|---|---|---|
| `trust/ca.crt` | replace test PEM with the Venafi root | `compute_matrix.py --bootstrap` → `true` |
| `terraform/bootstrap/` | none — `notary_ca_certificate` already sourced from the file | in-place validator update, **id stable** |
| cluster terraform | **none** | trust policies keep resolving `validator_id` via remote state — **zero cluster re-applies** |
| `scripts/render_bootstrap.py` | none | already reads `trust/ca.crt` via `common.load_ca_cert()` |
| `scripts/sign-image.sh` | add a plugin path: `notation plugin install`, then `notation key add --plugin venafi-csp --id <cert-label> --plugin-config config=...` | the file-key path (~60 lines: PEM validation, `signingkeys.json` merge, macOS config-dir handling) becomes local-testing-only |
| `.github/workflows/unikube.yaml` | `NOTATION_SIGNING_CERT` / `NOTATION_SIGNING_KEY` → a CSM service-account token, ideally OIDC-federated | one fewer private key in GitHub secrets |
| `self-built-image/.github/workflows/deploy.yaml` | the stubbed `NOTATION_KEY` / `NOTATION_CERT` secrets drop out | tenant repos stop carrying signing material entirely |
| `scripts/gen_signing_certs.sh` | none — keep it, relabel as local-test-only | already labelled "THIS SCRIPT IS TEST MATERIAL" |
| `trust/README.md`, `notation-signing.md` | update §4 (PKI), §7 (key custody) | doc-only |
| CODEOWNERS | none | `/trust/` rule already the strictest in the repo |

Worth noting how little moves. The bootstrap indirection — validator id read read-only from
remote state, CA cert rendered from a file rather than injected as a secret — was designed for
exactly this event, and it holds: **a full PKI migration is one file change plus one bootstrap
apply.**

The chain-completeness requirement is unchanged: the envelope must still carry
leaf → intermediate → root. Confirm the plugin emits the full chain; `sign-image.sh`'s
"refuse a bare leaf" check has no equivalent on the plugin path and its absence would surface as
an admission failure on a cluster rather than a red build.

### Do it now, not later

The cutover is a **hard cutover** — one certificate field, no verified bundle support, no
overlap window. Every image signed under the old root becomes unadmissible the instant
`trust/ca.crt` changes.

**Right now that cost is zero**, because `trust/ca.crt` is test material and nothing in
production has been signed under it. Every signed image from here on raises the price of a
migration that is already known to be necessary. If Venafi is the destination, the window to
arrive there for free is open and closing.

---

## 7. Questions to put to the PKI team / Venafi SE

In priority order — the first two determine whether Option A is buildable at all, and the third
determines whether Option B has any remaining advantage.

1. Can Venafi issue certificates on the **Notary code-signing leaf profile**
   (`CA:FALSE`, `keyUsage digitalSignature` only, EKU `codeSigning`, no `serverAuth` /
   `clientAuth` / `timeStamping` / `anyEKU`)? Via ZTPKI, Code Sign Manager, or both?
2. Can we have a **dedicated hierarchy** — a root used for nothing but container image signing —
   under Venafi HSM custody? What is the approval path for it as an internal CA?
3. Can that dedicated root carry **CDP/AIA** with Venafi-hosted CRL/OCSP? *(If yes, Option B
   loses its only structural advantage.)*
4. Can the Code Sign Manager **timestamp service be disabled** per project, and asserted in
   configuration rather than by convention?
5. Can a signing project **auto-approve** for a CI service identity, with the audit record as the
   compensating control?
6. Does the plugin emit the **complete chain** in the signature envelope?
7. Do build runners have **egress to the Venafi SaaS control plane** through the proxy allowlist?
8. What is the org root's actual `notAfter`, and its rotation plan? *(Needed to size Option B's
   calendar risk honestly, whichever way the decision goes.)*

Questions 1, 2 and 4 are also worth confirming in a spike before the design is committed —
vendor documentation is thin on all three, and each of them can invalidate a decision above.

---

## Sources

Repo (authoritative for current state):
[`notation-signing.md`](notation-signing.md) ·
[`trust/README.md`](../container-vulnerability-exemption/trust/README.md) ·
[`terraform/bootstrap/main.tf`](../container-vulnerability-exemption.tf/terraform/bootstrap/main.tf) ·
[`scripts/sign-image.sh`](../container-vulnerability-exemption/unikube/scripts/sign-image.sh) ·
[`scripts/gen_signing_certs.sh`](../container-vulnerability-exemption/unikube/scripts/gen_signing_certs.sh)

Vendor:

- [Zero Touch PKI overview](https://docs.venafi.cloud/ztpki/getting-started/overview-ztpki/) — private PKI-as-a-service, root + intermediate hierarchies, hardware-based key storage
- [Using Zero Touch PKI in the Control Plane](https://docs.venafi.cloud/vaas/certificates/ca/adding-ztpki-ca/) — adding a ZTPKI CA to the Control Plane
- [`Venafi/notation-venafi-csp`](https://github.com/Venafi/notation-venafi-csp) — official Notation plugin; badged for **Code Sign Manager SaaS** and self-hosted 23.1+; key specs, envelope formats, plugin capabilities
- [CodeSign Protect Guide 25.1 (PDF)](https://docs.venafi.com/Docs/25.1PDF/Code_Signing_Guide.pdf) — key custody, approval workflows, timestamp service
- [Venafi Zero Touch PKI announcement](https://www.businesswire.com/news/home/20201005005255/en/Venafi-Debuts-Venafi-Zero-Touch-PKI) — FIPS 140-2 HSM-backed root and intermediate storage

Specifications (unchanged from `notation-signing.md`):

- [Trust store and trust policy specification](https://github.com/notaryproject/specifications/blob/main/specs/trust-store-trust-policy.md)
- [Signature specification](https://github.com/notaryproject/specifications/blob/main/specs/signature-specification.md) — certificate profiles
