# Notation image signing — certificate requirements + local tutorial

**Start with [§1](#1-certificate-requirements). Before wiring anything to Venafi, confirm the
certificates you were given can actually be used.** Notation enforces a strict X.509 profile **at
signing time**, so a non-conforming certificate fails immediately — and the fix lives in the
issuing CA's template, not in Venafi.

The rest is a runnable tutorial: build an image, push it to a local registry, sign it with a
self-signed CA ([§4](#4-option-1--self-signed-ca)), then with Venafi
([§5](#5-option-2--venafi-codesign-protect)).

```
check-notary-profile.sh   checks any chain against the profile in §1     <- run this first
gen-signing-certs.sh      builds a conforming test PKI for Option 1
Dockerfile                trivial image, just to have a digest to sign
```

Self-contained; nothing here references files outside this folder.

---

## 1. Certificate requirements

Source: [Notary Project signature specification — Certificate Requirements][spec]. These are
validated **both when signing and when verifying**, and apply to every certificate in the chain.

[spec]: https://github.com/notaryproject/specifications/blob/main/specs/signature-specification.md#certificate-requirements

### 1.1 The profile

**Every certificate — root, intermediate and leaf:**

| Requirement | Rule |
|---|---|
| `keyUsage` | MUST be present and **MUST be marked critical** |
| Signature algorithm | MUST NOT be `sha1WithRSA` or `ecdsa-with-SHA1` anywhere in the chain |
| Validity | every certificate MUST be valid at signing time — and, with no timestamping, at *verification* time too |

**Root and intermediate (CA certificates):**

| Extension | Rule |
|---|---|
| `basicConstraints` | MUST be present, **MUST be critical**, `cA = TRUE` |
| `pathLenConstraint` | OPTIONAL; if present, must accommodate the depth below it |
| `keyUsage` | MUST contain `keyCertSign`. `cRLSign` is permitted |

**Leaf (the signing certificate):**

| Extension | Rule |
|---|---|
| `basicConstraints` | OPTIONAL; if present, `cA = FALSE` |
| `keyUsage` | MUST contain `digitalSignature` |
| `keyUsage` — forbidden | MUST NOT contain `keyCertSign`, `cRLSign`, `keyEncipherment`, `dataEncipherment`, `keyAgreement`, `encipherOnly`, `decipherOnly` |
| `extendedKeyUsage` | OPTIONAL; MAY contain `codeSigning`. MUST NOT contain `serverAuth`, `clientAuth`, `emailProtection`, `timeStamping`, `anyExtendedKeyUsage` |
| Key length | RSA ≥ 2048 bits, ECDSA ≥ 256 bits |

**The chain itself:**

- Ordered leaf → intermediate(s) → root, and MUST include the root.
- MUST NOT chain to multiple parents, and MUST NOT contain unrelated certificates.
- Only `basicConstraints`, `keyUsage` and `extendedKeyUsage` are evaluated. All other extensions
  are ignored, so anything else on the certificate is harmless.

> **Why `critical` matters.** A critical extension is one a client must either understand or
> reject. Marking `keyUsage` critical means no verifier can silently skip the check that this key
> is allowed to sign. It's a single bit, and it's the most common defect.

### 1.2 Beyond the spec — what this setup also needs

Not enforced by Notation, but each will bite later:

| Requirement | Why |
|---|---|
| Key type is RSA **2048/3072/4096** or EC **256/384/521** | The Venafi notation plugin supports only these. CodeSign Protect will happily issue Ed25519 or RSA-8192 keys, which the plugin cannot use. |
| Leaf validity ≈ **365 days** | With no timestamping, leaf lifetime *is* how long a signed image stays deployable. |
| Full subject DN — `C`, `ST`, `O`, `OU` | A leaf with only `CN` and `O` cannot be pinned by a valid `trustedIdentities` policy. Costs nothing now, impossible to retrofit. |
| A root used **only** for image signing | The trust anchor is an authorization boundary — see [§2](#2-why-the-trust-anchor-matters). |

### 1.3 Check the certificates you were given

```bash
./check-notary-profile.sh leaf.chain
# or, for separately retrieved files:
./check-notary-profile.sh leaf.crt intermediate.crt root.crt
```

It splits the chain, classifies each certificate as CA or leaf from its `basicConstraints`,
applies the rules for that tier, and exits non-zero if anything fails:

```
[1] leaf: C = US, ST = WA, O = ..., CN = Team-Image-Signing
   FAIL  keyUsage present but NOT critical  <-- MUST be critical
   PASS  basicConstraints CA:FALSE
   PASS  keyUsage contains digitalSignature
[2] CA: ... CN = Team-Image-Signing-Intermediate-1
   FAIL  keyUsage present but NOT critical  <-- MUST be critical
```

**Check the whole chain, not just the certificate named in an error message.** A misconfigured
template usually breaks several tiers at once, and each re-issue is a round trip through another
team.

By hand, the word `critical` is the whole point:

```bash
openssl x509 -in leaf.crt -noout -text | grep -A1 "X509v3 Key Usage"
```

```
X509v3 Key Usage: critical      <-- correct
    Digital Signature

X509v3 Key Usage:               <-- the defect
    Digital Signature
```

A known-good reference is available locally — `./gen-signing-certs.sh` produces a chain that passes
every rule above. This is exactly what `openssl x509 -noout -text` should print for each tier:

```
ROOT                                        INTERMEDIATE
  X509v3 Basic Constraints: critical          X509v3 Basic Constraints: critical
      CA:TRUE, pathlen:1                          CA:TRUE, pathlen:0
  X509v3 Key Usage: critical                  X509v3 Key Usage: critical
      Certificate Sign, CRL Sign                  Certificate Sign, CRL Sign
  Signature Algorithm: sha256WithRSAEncryption

LEAF
  X509v3 Basic Constraints: critical
      CA:FALSE
  X509v3 Key Usage: critical
      Digital Signature                     <- and nothing else
  X509v3 Extended Key Usage:
      Code Signing                          <- and nothing else
  Public-Key: (4096 bit)
  subject=C = US, ST = WA, O = ExampleOrg, OU = Platform-Unikube, CN = unikube-image-signer
```

Note `Certificate Sign` is openssl's rendering of `keyCertSign`, and `CRL Sign` of `cRLSign`.
Putting this side by side with the certificates you were given is the fastest way to spot the
difference.

### 1.4 If the certificates fail

The symptom, at signing time:

```
error: failed to sign with the plugin venafi-csp: generated signature failed verification:
certificate chain is invalid, certificate with subject "...": key usage extension must be
marked critical
```

**This cannot be fixed by re-issuing in Venafi.** Venafi submits a CSR; the **issuing CA** decides
which extensions appear and whether they are critical, according to its **certificate template**.
Re-enrolling against an unchanged template reproduces the same certificate. The template must
change first. On Microsoft ADCS: *Certificate Template → Properties → Extensions → Key Usage →
Edit → "Make this extension critical"*.

Cost depends on which tier is wrong:

| Faulty tier | Fix | Impact |
|---|---|---|
| Leaf | fix template, re-enroll the environment's certificate | small — same label, nothing else changes |
| Intermediate | fix profile, re-issue intermediate, then the leaf | moderate — **trust anchor unchanged** |
| Root | regenerate the root | **new trust anchor**, everything below re-issued |

**If the root is wrong, now is the cheapest moment to find out** — nothing is signed, no anchor is
deployed. The same discovery after go-live is a fleet-wide re-signing event. Say so when you
report it.

<details>
<summary><b>Request to send to the PKI team</b></summary>

> **Subject: Team-Image-Signing certificates need `keyUsage` marked critical — template change,
> not a re-issue**
>
> The code-signing certificates for the `Team Image Signing` project can't be used for container
> image signing as issued. Notation rejects the chain at signing time:
>
> ```
> certificate chain is invalid, certificate with subject "<SUBJECT>":
> key usage extension must be marked critical
> ```
>
> The certificates are valid X.509 — the issue is that **`keyUsage` is not marked critical**,
> which the Notary Project signature specification requires for both CA and code-signing
> certificates:
>
> > *Root and Intermediate CA Certificates* — "the `keyUsage` extension MUST be present and MUST
> > be marked critical. Bit positions for `keyCertSign` MUST be set."
> > *Leaf Certificates* — "the `keyUsage` extension MUST be present and MUST be marked critical.
> > Bit positions for `digitalSignature` MUST be set."
> > — https://github.com/notaryproject/specifications/blob/main/specs/signature-specification.md#certificate-requirements
>
> Affected certificates: **&lt;paste check-notary-profile.sh output&gt;**
>
> **Re-issuing from the current template won't fix this** — criticality is set by the issuing CA's
> certificate template, not by Venafi. On ADCS that's *Certificate Template → Properties →
> Extensions → Key Usage → Edit → "Make this extension critical"*.
>
> While the template is open, could you confirm the rest of the profile: `basicConstraints`
> critical with `CA:TRUE` on the CA certificates; on the leaf `digitalSignature` only (no
> `keyCertSign`, `cRLSign`, `keyEncipherment`); EKU containing at most `codeSigning` and **not**
> `serverAuth`, `clientAuth`, `emailProtection`, `timeStamping` or `anyExtendedKeyUsage`; RSA
> 2048/3072/4096 or EC 256/384/521; subject DN including `C`, `ST`, `O` and `OU`; and no SHA-1
> signatures anywhere in the chain.
>
> **Timing:** nothing has been signed with these certificates yet, so re-issuing now costs
> nothing. Once images are signed in production, changing a certificate means re-signing them —
> and changing the *root* means re-signing everything and updating the admission controller's
> trust anchor.

</details>

---

## 2. Why the trust anchor matters

An admission controller verifies a signature by checking that the chain terminates in a CA
certificate given to it in advance — the **trust anchor**. Two consequences shape everything else.

**The anchor is an authorization boundary, not an identity check.** Our admission controller (Wiz)
accepts one input: which CA certificate(s) to trust. It cannot additionally require *"and the
signing certificate must be this one"* — the Notary spec calls that `trustedIdentities`, and Wiz
doesn't implement it. So **anything chaining to the anchor is admitted, fleet-wide**. That's why
the anchor must be a CA used for nothing but image signing, rather than a general-purpose
corporate root. [§4.6](#44-two-leaves-one-root--what-the-anchor-cannot-distinguish) demonstrates
this on your laptop.

**Certificate expiry is the revocation mechanism.** We deliberately don't use trusted
timestamping: without it, every certificate in the chain must be valid *now*, so a leaked key
stops being useful when its certificate expires — a bound an attacker cannot extend. A timestamped
signature survives expiry indefinitely. This gets "fixed" by well-meaning people; don't enable it.

---

## 3. Prerequisites

```bash
export DEMO_DIR="$PWD"
export REGISTRY="localhost:5001"
export IMAGE="${REGISTRY}/venafi-demo:v1"

# notation's config dir is NOT XDG-portable: macOS ignores XDG_CONFIG_HOME entirely.
case "$(uname -s)" in
  Darwin) export NOTATION_DIR="$HOME/Library/Application Support/notation" ;;
  *)      export NOTATION_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/notation" ;;
esac
```

**Registry, build, push, digest:**

```bash
docker run -d --name venafi-demo-registry -p 5001:5000 \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true registry:3

docker build -t "$IMAGE" "$DEMO_DIR"
docker push "$IMAGE"

export IMAGE_DIGEST="$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE")"
echo "$IMAGE_DIGEST"
```

`registry:3` implements the OCI 1.1 Referrers API, which is how signatures are attached and
discovered. Older registries fall back to the referrers *tag* schema — still works, worth knowing
if signatures seem to vanish.

- **Push before sign.** A signature is an OCI artifact whose subject is the image manifest *in the
  registry*; there's nothing to attach to until the image exists remotely.
- **Sign the digest, never the tag.** A tag can be repointed after review.

**Notation CLI** — v1.3.2 is what the Venafi plugin is tested against:

```bash
brew install notation      # macOS
# Linux: download notation_<version>_<os>_<arch>.tar.gz from
# https://github.com/notaryproject/notation/releases
notation version
```

**Allow the plain-HTTP local registry** (real registries need none of this):

```bash
mkdir -p "$NOTATION_DIR"
# WARNING: overwrites config.json — back it up if you already use notation.
cat > "$NOTATION_DIR/config.json" <<JSON
{
    "insecureRegistries": ["localhost:5001"]
}
JSON
```

---

## 4. Option 1 — self-signed CA

Keys on disk, no external services. Useful as a **known-good reference** for §1 and to see the
trust-anchor problem first-hand.

### 4.1 Generate the PKI

```bash
./gen-signing-certs.sh
export PKI="$DEMO_DIR/pki"
./check-notary-profile.sh "$PKI/signing-chain.crt"     # every rule in §1 passes
```

| File | What it is |
|---|---|
| `root.crt` | the **trust anchor** — what a verifier is given |
| `intermediate.crt` | issuing CA; travels in the chain |
| `signing.crt` / `signing.key` | the leaf and **its private key, on your filesystem** |
| `signing-chain.crt` | leaf + intermediate + root — **sign with this** |

The script prints `CHAIN LIFETIMES`. The number that matters is the **effective** lifetime: the
earliest expiry in the chain, not the leaf's.

### 4.2 Register the key

`notation key add` handles **plugin** keys only; on-disk key/cert pairs are registered by writing
`signingkeys.json` directly, with **absolute paths**:

```bash
cat > "$NOTATION_DIR/signingkeys.json" <<JSON
{
    "default": "local-signer",
    "keys": [
        { "name": "local-signer", "keyPath": "${PKI}/signing.key", "certPath": "${PKI}/signing-chain.crt" }
    ]
}
JSON
notation key ls
```

**`certPath` must be the chain, not `signing.crt`.** A bare leaf signs without complaint and then
fails verification.

### 4.3 Sign, inspect, verify

```bash
notation sign --signature-format cose --key local-signer "$IMAGE_DIGEST"
notation inspect "$IMAGE_DIGEST"      # 'certificates' should list THREE entries
```

```bash
notation certificate add --type ca --store demo-local "$PKI/root.crt"

cat > "$DEMO_DIR/trustpolicy.json" <<'JSON'
{
    "version": "1.0",
    "trustPolicies": [{
        "name": "demo-local",
        "registryScopes": [ "*" ],
        "signatureVerification": { "level": "strict" },
        "trustStores": [ "ca:demo-local" ],
        "trustedIdentities": [ "*" ]
    }]
}
JSON

notation policy import --force "$DEMO_DIR/trustpolicy.json"
notation verify "$IMAGE_DIGEST"
```

Verify against the **root**, not the intermediate. Note `trustedIdentities: ["*"]` — per the spec
that means *any* certificate issued by a CA in the trust store. **It is the only mode Wiz can
express.**

### 4.4 Two leaves, one root — what the anchor cannot distinguish

Issue a signing certificate for a *different team* from the same intermediate, and sign a second
image with it:

```bash
./gen-signing-certs.sh --second-leaf
openssl x509 -in "$PKI/signing-team-b.crt" -noout -subject
# ... OU = Other-Team, CN = other-team-signer

docker build --build-arg VARIANT=b -t "${REGISTRY}/venafi-demo:v2" "$DEMO_DIR"
docker push "${REGISTRY}/venafi-demo:v2"
export IMAGE_B_DIGEST="$(docker inspect --format='{{index .RepoDigests 0}}' "${REGISTRY}/venafi-demo:v2")"
```

Add it to `signingkeys.json` as a second entry named `team-b-signer` (the `keys` array takes
several), then:

```bash
notation sign --signature-format cose --key team-b-signer "$IMAGE_B_DIGEST"
notation verify "$IMAGE_DIGEST"      # PASSES
notation verify "$IMAGE_B_DIGEST"    # ALSO PASSES
```

Nothing here is a misconfiguration — issuing to multiple teams is what a shared CA is *for*. But
**both images are accepted**, because the only question asked was "does this chain to `root.crt`?"

Now pin the signer. Replace `"trustedIdentities": [ "*" ]` with:

```json
"trustedIdentities": [ "x509.subject: C=US, ST=WA, O=ExampleOrg, OU=Platform-Unikube" ]
```

```bash
notation policy import --force "$DEMO_DIR/trustpolicy.json"
notation verify "$IMAGE_DIGEST"      # PASSES
notation verify "$IMAGE_B_DIGEST"    # FAILS — signing certificate not in trusted identities
```

That second failure is the control we want, and **Wiz cannot express it** — it is permanently in
`"*"` mode, where both images are admitted. Hence: the trust anchor must be a CA used for nothing
else. Pin at `OU`, not `CN`, since the annual leaf rotation changes the CN.

### 4.5 What this proves

**The anchor is the boundary** — anything chaining to `root.crt` is admitted, and the narrowing
control doesn't exist in Wiz.

**The key is a liability** — `signing.key` sits in `./pki/`, and in CI it would be a secret in an
environment variable. Whoever holds it can sign anything, for up to a year, with no audit trail.
Option 2 fixes this second problem; only a dedicated root fixes the first.

---

## 5. Option 2 — Venafi CodeSign Protect

Same `notation sign` command. The difference: **no private key exists on this machine** — signing
is an API call to Venafi, which signs inside its HSM.

### 5.1 What must exist on the Venafi side

| # | Thing | Who |
|---|---|---|
| 1 | A **dedicated code-signing hierarchy** — its own root, not the corporate root ([§2](#2-why-the-trust-anchor-matters)) | PKI |
| 2 | A **certificate template** matching the profile in [§1](#1-certificate-requirements) | PKI |
| 3 | A **CA template** in Venafi pointing at (2) — every environment needs one | Code Signing Admin |
| 4 | An **Environment Template** — you can't create a project without access to one | Code Signing Admin |
| 5 | A **Project + Environment** — type *single*, key generated in the HSM, TPP-managed lifecycle | you request, admin approves |
| 6 | A **Flow with no approval action** — otherwise signing blocks waiting for a human | Code Signing Admin |
| 7 | The **`vsign-sdk` API Integration** with your user assigned, scope `codesignclient;codesign;certificate:manage,discover` | TPP admin |
| 8 | **Timestamping left off** ([§2](#2-why-the-trust-anchor-matters)) | Code Signing Admin |

Venafi is a control plane, not a CA — it connects to one (Microsoft CA/ADCS, EJBCA, Entrust,
DigiCert, Sectigo, or self-signed). Items 1–2 happen on that CA, possibly with a different team.

### 5.2 Client tools and an access token

`pkcs11config` ships with the **CodeSign Protect client**, a separate download from the Venafi
server. Note it belongs to the PKCS#11 path — the notation plugin uses the REST API via the vSign
SDK, so you need `pkcs11config` only to *discover* certificate labels.

The plugin needs an `access_token`, not a username and password:

```bash
export TPP_URL='https://codesigningapi.test.org'

# with the vsign CLI (go install github.com/venafi/vsign/cmd/vsign@latest)
vsign getcred --url "$TPP_URL" --username 'your-user' --password 'your-password'

# or directly
curl -sS -X POST "${TPP_URL}/vedauth/authorize/oauth" \
  -H 'Content-Type: application/json' \
  -d '{"client_id":"vsign-sdk","username":"your-user","password":"your-password",
       "scope":"codesignclient;codesign;certificate:manage,discover"}'

export TPP_ACCESS_TOKEN='...'
```

Common failures: `vsign-sdk` doesn't exist or your user isn't assigned to it (item 7); local TPP
identities often need a `local:` prefix on the username; and the internal TLS certificate of
`codesigningapi.test.org` may not be trusted — vSign takes a `trust_bundle` option for that (a
*different* certificate from the code-signing chain).

For CI later, use `jwt`/`VSIGN_JWT` to exchange a short-lived OIDC token rather than storing a
long-lived one.

### 5.3 Retrieve the certificates and check them

```bash
pkcs11config listobjects
```

For this environment that returns three labels — one per tier, each with a different job:

| Label | Tier | Used for |
|---|---|---|
| `Team-Image-Signing` | leaf | signing → `CERT_LABEL` |
| `Team-Image-Signing-Intermediate-1` | intermediate | travels inside the signature |
| `Team-Image-Signing-Root` | root | verification → trust store, and the admission controller |

**Never put the intermediate in a trust store.** The Notary spec warns this is certificate pinning
that "can break signature verification unexpectedly anytime the intermediate certificate is
rotated" — and the `-1` suffix says an `Intermediate-2` is already planned.

```bash
pkcs11config getcertificate -label Team-Image-Signing -file leaf.crt -chain leaf.chain
pkcs11config getcertificate -label Team-Image-Signing-Root -file team-image-signing-root.crt

./check-notary-profile.sh leaf.chain          # <-- §1. Do not proceed until this passes.
```

Also confirm the root is genuinely dedicated and self-signed:

```bash
openssl x509 -in team-image-signing-root.crt -noout -subject -issuer
# subject and issuer identical => self-signed => it is a root
```

A root named `Team-Image-Signing-Root` reads as purpose-built rather than the corporate root,
which is what [§2](#2-why-the-trust-anchor-matters) requires. If it turns out to be the
company-wide root, escalate — that's the [§4.6](#44-two-leaves-one-root--what-the-anchor-cannot-distinguish)
scenario at company scale.

### 5.4 Configure and sign

Three names, three spellings, none interchangeable:

| | Value |
|---|---|
| Project | `Team Image Signing` |
| Environment | `TeamImageSigning` |
| → `tpp_project` | `Team Image Signing\TeamImageSigning` |
| Certificate label → `CERT_LABEL` | `Team-Image-Signing` |

```bash
notation plugin install \
  --url https://github.com/Venafi/notation-venafi-csp/releases/download/v0.3.0/notation-venafi-csp-linux-amd64.tar.gz \
  --sha256sum 03771794643f18c286b6db3a25a4d0b8e7c401e685b1e95a19f03c9356344f5a

export TPP_PROJECT='Team Image Signing\TeamImageSigning'   # single quotes: backslash + spaces
export CERT_LABEL='Team-Image-Signing'

umask 077
cat > "$DEMO_DIR/config.ini" <<INI
tpp_url = ${TPP_URL}
access_token = ${TPP_ACCESS_TOKEN}
tpp_project = ${TPP_PROJECT}
INI
chmod 600 "$DEMO_DIR/config.ini"
grep tpp_project "$DEMO_DIR/config.ini"    # confirm the backslash and spaces survived

notation key add --default "$CERT_LABEL" --plugin venafi-csp --id "$CERT_LABEL" \
  --plugin-config "config=$DEMO_DIR/config.ini"

notation sign --signature-format cose --key "$CERT_LABEL" "$IMAGE_DIGEST"
```

`tpp_url` is the **base** URL — no path suffix; the SDK appends `/vedauth` and `/vedsdk`. That
sha256 is for **linux-amd64 v0.3.0** only; take others from the
[release page](https://github.com/Venafi/notation-venafi-csp/releases). In CI, mirror the plugin
binary internally rather than pulling from GitHub on every build.

Compare with [§4.2](#42-register-the-key): no `keyPath`, no `certPath`, nothing on disk to point at.

### 5.5 Inspect and verify

```bash
notation inspect "$IMAGE_DIGEST"
```

**Count the `certificates` entries.** In Option 1 you controlled the chain file, so three was
guaranteed. Here the chain comes from whatever the CodeSign Protect environment holds, and the
vendor docs don't state whether that's the full chain or a bare leaf. **One entry = bare leaf =
stop** — signing succeeded, the admission controller will reject the image, and you'd find out on
a cluster. It's fixable environment configuration, not a dead end.

```bash
notation certificate add --type ca --store team-image-signing "$DEMO_DIR/team-image-signing-root.crt"
# reuse trustpolicy.json from §4.3 with trustStores: [ "ca:team-image-signing" ]
notation policy import --force "$DEMO_DIR/trustpolicy.json"
notation verify "$IMAGE_DIGEST"
```

### 5.6 Troubleshooting

| Symptom | Cause |
|---|---|
| `key usage extension must be marked critical` | certificate profile — **[§1.4](#14-if-the-certificates-fail)** |
| hangs, or "pending approval" | the Flow has an approval action — item 6 |
| 401 / unauthorized | token expired, or scope too narrow |
| "signing key not found" | `tpp_project` or `CERT_LABEL` wrong — check the quoting in §5.4 |
| x509 / TLS error | internal CA not trusted — set `trust_bundle` |
| forbidden from this address | your IP is outside the Environment's permitted range |
| registry refused | `localhost:5001` not allowlisted — §3 |

### 5.7 Staging is not production

The staging root is **not** the production trust anchor — keep it away from the production
admission controller. Everything in §5.1 recurs for production on a different hierarchy, so
resolve §1 now while it's cheap. Ask explicitly whether production will be structured the same
way: if staging was quietly issued under the corporate root because it's "only staging",
production may default to the same.

---

## 6. Cleanup

```bash
docker rm -f venafi-demo-registry
notation key delete local-signer team-b-signer 2>/dev/null
notation key delete "$CERT_LABEL" 2>/dev/null
notation certificate delete --type ca --store demo-local --all -y 2>/dev/null
rm -rf "$DEMO_DIR/pki" "$DEMO_DIR/config.ini" "$DEMO_DIR/trustpolicy.json"
```

`./pki/` holds private keys in the clear and is gitignored. Don't reuse those certificates for
anything real.

**Not covered here:** whether an image *should* be signed — in the real pipeline a compliance
check gates signing, and the `Dockerfile` here is `FROM alpine` purely to have a digest. And
`notation verify` proves what *Notation* concludes; Wiz's own trust policy isn't ours to inspect.
