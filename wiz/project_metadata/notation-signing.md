# Notation signing — how it actually works here

Operational reference for the signing half of the system. [`image-signing-101.md`](image-signing-101.md)
is the conceptual primer (digests, labels, why not to trust labels); this document is the
Notation/Notary specifics: what verification checks, why our PKI is shaped the way it is, and
which rotations have deadlines.

Everything here traces to one constraint, so it is worth stating first:

> **`wiz-v2_image_integrity_validator` accepts exactly one field: `certificate`.**
> No signer-identity pinning, no timestamp-authority trust store, no certificate bundle.

Almost every decision below is downstream of that. If Wiz ever adds identity pinning, most of
this document should be revisited — see [Open questions](#open-questions-for-the-wiz-spike).

---

## 1. The three clocks

These get conflated constantly. They are independent mechanisms with different owners.

| Clock | Set by | What it does | Us |
|---|---|---|---|
| **Certificate validity** (`notBefore`/`notAfter`) | the CA that issued it | with no timestamp, verification requires **every** cert in the chain to be valid **right now** | **this is our only clock** |
| **Timestamp countersignature** (RFC 3161, from a TSA) | a Timestamp Authority at signing time | changes the question from "valid now?" to "was it valid when signed?" — cert expiry stops mattering | **not used; unusable with Wiz** |
| **Signature `expiry`** (signed attribute) | **the signer**, optionally, at signing time | a "best by use" date on the artifact itself | not used |

Two consequences people get wrong:

- **A timestamp does not give a validity window.** It makes a signature durable *indefinitely*.
  The year-shaped control is `expiry`, which is a separate, optional attribute.
- **`expiry` is no defence against a stolen key.** The spec defines it as *"an OPTIONAL claim
  … as defined by the signer"*, not set by default. An attacker holding the signing key sets
  it to 2099 or omits it. It constrains honest signers only.

Which is why the no-TSA model is not merely a default we inherited:

| | Bound on damage from a leaked signing key |
|---|---|
| **No TSA** (ours) | certificate expiry — bounded, automatic, attacker cannot extend it |
| **TSA + signature `expiry`** | none — the attacker chooses the expiry |

We buy a hard upper bound on compromise, and pay for it by having certificate rotation and
image admissibility be the same event. That trade is the root of §4.

---

## 2. What verification actually checks

Five validations. The trust policy's `level` decides which are *enforced* (failure fails
verification) vs merely *logged*.

| # | Validation | What it means | Enforced at `strict` | at `permissive` | at `audit` |
|---|---|---|---|---|---|
| 1 | **Integrity** | artifact unaltered, signature not corrupted | ✅ | ✅ | ✅ |
| 2 | **Authenticity** | chain terminates in the trust store, and `trustedIdentities` matches | ✅ | ✅ | logged |
| 3 | **Authentic timestamp** | *no TSA:* whole chain valid **now**. *TSA:* signing time inside chain validity | ✅ | logged | logged |
| 4 | **Expiry** | the optional signature `expiry` attribute has not passed | ✅ | logged | logged |
| 5 | **Revocation** | signing identity still trusted (CRL/OCSP) | ✅ | logged | logged |

Two things worth internalising:

**Validation 3 runs on every admission decision, not once at push.** An image admitted all day
yesterday is refused this morning if a certificate in its chain lapsed overnight. Nothing about
the image changed. This *is* our revocation mechanism, and it is also why leaf rotation is a
deadline rather than a chore.

**Validation 5 is currently a no-op.** The spec: *"If the certificate being validated doesn't
include information OCSP or CRLs then no revocation check is performed and the certificate is
considered valid."* Our certificates carry neither CDP nor AIA extensions, so `strict` enforces
a revocation check that always passes. Real revocation would need those extensions **and**
network reachability from the Wiz admission controller through the proxy allowlist — unverified.

---

## 3. Trust store vs trusted identities — why we own a root

Notation asks two separate questions:

| Layer | Question | Where |
|---|---|---|
| **Trust store** | does the chain terminate in a CA we trust? | `trust/ca.crt` → `notary_ca_certificate` |
| **`trustedIdentities`** | is the *signing certificate* ours? | trust policy — **Wiz has no equivalent** |

Per the spec, `trustedIdentities: ["*"]` means *"any signing certificate issued by a CA in
trustStore is allowed"*; otherwise `x509.subject` entries are matched against the **signing
certificate's** subject.

Because Wiz only implements the first layer, **a CA in our trust store is an unrestricted
admission authority**. That single fact rules out three otherwise-obvious designs:

- **The org root CA.** Any team with an org-issued certificate could sign an image and have it
  admitted on all ~200 clusters. The org root is a broad identity provider, not an
  authorization boundary.
- **AWS Signer.** Its trust anchor is AWS Signer's root, shared with every AWS Signer customer;
  AWS's own docs state the built-in trust policy *"enforces that all images must be signed by
  the AWS Signer signing profile"* — i.e. the boundary is `trustedIdentities`, which we cannot
  express. Trusting that root would accept signatures from any AWS customer.
- **A team intermediate placed directly in the trust store.** Spec advises against it:
  *"placing intermediate certificates in the trust store is not recommended as this is a form
  of certificate pinning that can break signature verification unexpectedly anytime the
  intermediate certificate is rotated."*

Hence a **standalone signing root used for nothing else**, so that "chains to this root" and
"signed by our pipeline" are the same statement — enforced by key custody rather than by policy.

**We still issue full DNs** (`C`, `ST`, `O`, `OU`) on every certificate even though Wiz cannot
use them. It costs nothing, makes local `notation verify` a genuine check, and is a
prerequisite the day Wiz gains pinning or enforcement moves to Kyverno (which supports
`trustedIdentities` today).

---

## 4. The PKI

```
ExampleOrg Container Signing Root CA     10y   offline, HSM      -> trust/ca.crt, into Wiz
  └─ Unikube Image Signing CA (issuing)   5y   HSM               -> travels in the chain
       └─ unikube-image-signer (leaf)   365d   CI env / KMS      -> signs images
```

### Why three tiers, honestly

The usual argument — "keeps the root offline" — is weak here, because we issue a leaf roughly
once a year and an annual offline-root ceremony would be perfectly normal. Two tiers
(root → leaf) is a defensible design and was seriously considered.

The argument that decides it is **blast radius**:

| Event | Two-tier | Three-tier |
|---|---|---|
| Leaf key compromised | re-issue leaf | re-issue leaf |
| **Issuing key compromised** | the issuing key *is* the root → replace `trust/ca.crt` → **every image in both tenants unadmissible, all must be re-signed** | issue a new intermediate; the gate never changes |
| HSM migration / signing moves teams | same fleet-wide event | new intermediate, invisible at the gate |

A root swap is the only unrecoverable event in this design: one certificate field, no verified
bundle overlap, no identity pinning to soften it. One extra certificate is a cheap premium
against ever being forced into it.

### Why the leaf is 365 days, and why that is uncomfortable

Best practice is short-lived signing certificates. We cannot have them: with no TSA, **the
leaf's lifetime is the image's admissibility lifetime**. A 30-day leaf would mean re-signing
every image monthly. 365 days is the compromise — and it means a leaked leaf key stays usable
for up to a year, since expiry is our only revocation.

### Why you cannot sign with the intermediate

Not style — the profiles are mutually exclusive:

| | Leaf (signing) | CA (root/intermediate) |
|---|---|---|
| `basicConstraints` | `CA:FALSE` | `CA:TRUE` (critical) |
| `keyUsage` | `digitalSignature`; `keyCertSign`/`cRLSign` **MUST NOT** be set | `keyCertSign` **MUST** be set |
| `extendedKeyUsage` | may contain `codeSigning`; must not contain `serverAuth`, `clientAuth`, `timeStamping`, `anyExtendedKeyUsage` | n/a |
| key size | RSA ≥ 2048 | — |

A CA certificate used as a signing certificate fails the leaf profile and is rejected. The
operational reason the spec is shaped this way: signing with the intermediate would mean
shipping a **CA private key to build runners**. A leaked leaf signs images; a leaked CA key
issues certificates.

### Why not mint an intermediate per build

It requires the **root key in CI on every run**. "Well guarded" and "reachable from every
pipeline" are the same key in two places, and the root is the entire authorization boundary.
It also wouldn't help: a fresh intermediate and its leaf, issued the same instant with the
same validity, expire together — that is leaf rotation with a CA-shaped detour, plus a growing
population of live issuing CAs under the root.

---

## 5. Rotation — the part with deadlines

**The governing rule:** with no timestamp, *"each and every certificate in the chain — signing
certificate, intermediate certificates, and the root certificate — must be valid at the time of
verification."*

So:

```
image admissibility  =  min(leaf.notAfter, intermediate.notAfter, root.notAfter)
```

Not the leaf alone. Four consequences that are easy to miss:

**1. A certificate must never outlive its issuer.** The spec permits issuing one —
*"implementations MUST NOT enforce validity period nesting"* — it simply doesn't help you.
Issue a 365-day leaf from an intermediate with 200 days left and the image dies in 200 days,
silently, while the leaf still shows a year of validity. Issuance must clamp:

```
leaf_days          = min(365,  intermediate_remaining_days − buffer)
intermediate_days  = min(1825, root_remaining_days         − buffer)
```

and fail loudly when the issuer is too close to expiry to produce a useful child. That turns a
silent truncation into "rotate the tier above, now". **The rule is recursive** — it applies to
the intermediate under the root exactly as it does to the leaf under the intermediate.

**2. Each tier's rotation deadline is derived from the tier below it.** Nothing is rotated
"together"; each must be replaced while its remaining life still exceeds a full child lifetime
plus buffer. With the chosen 10y / 5y / 365d and a 30-day buffer:

| Tier | Life | Must be replaced once remaining life drops below | i.e. by about |
|---|---|---|---|
| leaf | 365d | — (it is the bottom tier) | annually |
| intermediate | 5y (1825d) | 365 + 30 = **395 days** | **year 4** of its life |
| root | 10y (3650d) | 1825 + 30 = **1855 days** | **year 5** of its life |

The root row is the uncomfortable one: past roughly year 5, the root can no longer issue a
full-length intermediate, so intermediates start getting clamped and the root swap — the one
fleet-wide event — becomes unavoidable well before the root's nominal 10-year expiry. Plan the
root replacement for year ~5, not year 10.

**3. Rotating the intermediate is not a cutover, but old chains still age out.** New signatures
use the new chain immediately, and nothing already signed is invalidated. But images signed
under the *old* intermediate remain admissible only until that old intermediate expires — so
either re-sign them or let them age out deliberately.

**4. The local script enforces this.** `gen_signing_certs.sh` clamps every certificate against
its issuer's remaining life and **refuses** to issue a truncated one unless you pass
`--allow-short`; it also prints the effective admissibility (`min` of the chain) and which
tier governs it. The clamp only ever binds on **re-issue** — `--reissue-leaf`, which keeps the
root and intermediate and mints a new leaf — because in a fresh build every child is trivially
inside its parent. That is the annual rotation, and it is the case the check exists for.

Production issuance will be the PKI team's, not this script's; the behaviour is worth
mirroring in whatever they use, since the failure it prevents is silent.

| Rotates | Cadence | Touches `trust/ca.crt`? | Fleet impact |
|---|---|---|---|
| **leaf** | ~365 days | no | none — same intermediate |
| **intermediate** | by ~year 4 (see above) | no | none at the gate; old-chain images expire at the old intermediate's `notAfter` |
| **root** | by ~year 5, or on compromise | **yes** | hard cutover, both tenants, everything re-signed |

---

## 6. The signature itself

- Stored **in the registry** as an OCI artifact whose `subject` is the image manifest, discovered
  through the Referrers API. This is why **push precedes sign** — there is nothing to attach a
  signature to until the image exists remotely.
- Sign the **digest**, never the tag: a tag can be repointed between the compliance check and
  the signature.
- The envelope MUST carry the **complete chain**, leaf first, terminating at the root, and MUST
  NOT chain to multiple parents. A bare leaf signs without complaint and then fails verification
  at admission — `sign-image.sh` refuses one so the failure lands in CI instead of on a cluster.

---

## 7. If a key leaks

| Key | Attacker can | Contained by |
|---|---|---|
| **Leaf** | sign images admitted fleet-wide | leaf expiry — up to 365 days |
| **Intermediate** | issue leaves at will (`pathlen:0` blocks sub-CAs) | intermediate expiry — up to 5 years |
| **Root** | issue intermediates; total control of admission | nothing. Replace `trust/ca.crt`: fleet-wide, both tenants, all images re-signed |

There is no faster lever, because revocation (§2, validation 5) is a no-op without CDP/AIA. If
that is unacceptable, the fix is real CRL/OCSP — not a shorter leaf, which trades a compromise
window for a re-signing treadmill.

---

## 8. Open questions for the Wiz spike

Every one of these, if answered differently, reopens a decision above:

1. **Does the validator fail open or closed** when the Wiz backend is unreachable, and is policy
   cached? Decides whether enforcement can safely move from `AUDIT` to `BLOCK`.
2. **Does `notary_v2.certificate` accept a concatenated PEM bundle?** Decides whether root
   rotation can ever have an overlap window instead of a hard cutover.
3. **Is there any signer-identity check we cannot see?** If Wiz adds `trustedIdentities`
   equivalents, the org root and AWS Signer both become viable and this PKI can be retired.
4. **Is timestamp verification possible at all?** It requires a `tsa` trust store, which has
   nowhere to live in a one-field validator.
5. **Can the admission controller reach CRL/OCSP endpoints** through the proxy allowlist? Decides
   whether real revocation is available.

---

## 9. Verifying locally

The practical walkthrough — trust store, trust policy, `notation verify`, and reading its
failure modes — is step 4c of
[`../container-vulnerability-exemption/unikube/README.md`](../container-vulnerability-exemption/unikube/README.md).
Verify against the **committed** `trust/ca.crt`, not the copy in `out/pki/`: the latter is the
root the chain was just issued under and cannot disagree.

Note this proves only what *Notation* would conclude. It is not a security control against a
determined signer — an attacker with a key does not run our pipeline — and it cannot tell you
what **Wiz** will do, since Wiz's trust policy is not ours to inspect.

---

## Sources

- [Trust store and trust policy specification](https://github.com/notaryproject/specifications/blob/main/specs/trust-store-trust-policy.md) — verification steps, levels, `trustedIdentities`, timestamp triggering, revocation
- [Signature specification](https://github.com/notaryproject/specifications/blob/main/specs/signature-specification.md) — certificate profiles, chain requirements, `expiry`, signature storage
- [AWS Signer: prerequisites for signing container images](https://docs.aws.amazon.com/signer/latest/developerguide/image-signing-prerequisites.html) — shared root, profile-based trust policy
- [AWS Signer: SignatureValidityPeriod](https://docs.aws.amazon.com/signer/latest/api/API_SignatureValidityPeriod.html)
