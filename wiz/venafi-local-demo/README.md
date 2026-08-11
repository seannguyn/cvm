# Signing a container image with Notation — a local tutorial

Run this on a Mac or Linux laptop. You build an image, push it to a registry on localhost, and
sign it two different ways:

- **[Option 1 — self-signed CA](#option-1--self-signed-ca)**: keys on your filesystem. No external
  dependencies. Works right now.
- **[Option 2 — Venafi CodeSign Protect](#option-2--venafi-codesign-protect)**: the key lives in
  an HSM and never reaches your machine. Needs setup on the Venafi side first.

Do the [prerequisites](#prerequisites) once, then either option. Doing both back to back is the
point — the diff between them is the whole argument.

Option 1 ends by signing **two** images with **two different teams' certificates** under one CA
([1.6](#16-a-second-image-signed-by-a-second-leaf)–[1.7](#17-now-pin-the-signer--and-see-what-wiz-cant-do)).
That pair is the most useful thing in this folder: it reproduces, on a laptop, the exact reason
the trust anchor cannot be a shared corporate root.

This folder is self-contained. Everything you need is here.

```
Dockerfile             a trivial image, just to have something with a digest to sign
gen-signing-certs.sh   builds the test PKI for Option 1
README.md              this file
```

---

## Background — why any of this

A Kubernetes admission controller can be configured to reject images that aren't signed. It
verifies a signature by checking that the signing certificate's chain terminates in a CA
certificate you gave it in advance — the **trust anchor**.

Three consequences drive everything below.

**The trust anchor is an authorization boundary, not just an identity check.** Our admission
controller (Wiz) accepts exactly one input: which CA certificate(s) to trust. It has no way to
also say *"and only if the signing certificate is this specific one"* — the Notary spec calls
that `trustedIdentities`, and Wiz doesn't implement it. So **anything that chains to the anchor is
admitted, fleet-wide**. That's why the anchor must be a CA used for nothing but image signing,
rather than a general-purpose corporate root that issues certificates to every team.

**Certificate expiry is the revocation mechanism.** We deliberately do not use trusted
timestamping. Without it, verification requires every certificate in the chain to be valid *right
now*, so a leaked signing key stops being useful when its certificate expires — a bound the
attacker cannot extend. A timestamped signature, by contrast, survives its certificate's expiry
indefinitely. This is counter-intuitive and gets "fixed" by well-meaning people; don't enable
timestamping.

**The signing key is the crown jewel.** Whoever holds it can get any image admitted anywhere, for
up to a year, with no audit trail. Option 1 leaves that key on a filesystem. Option 2 is how you
stop doing that.

---

## Prerequisites

### 0. Set your working variables

Run everything from this directory.

```bash
export DEMO_DIR="$PWD"
export REGISTRY="localhost:5001"
export IMAGE="${REGISTRY}/venafi-demo:v1"

# notation's config dir is NOT XDG-portable: macOS ignores XDG_CONFIG_HOME entirely.
case "$(uname -s)" in
  Darwin) export NOTATION_DIR="$HOME/Library/Application Support/notation" ;;
  *)      export NOTATION_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/notation" ;;
esac
echo "notation config dir: $NOTATION_DIR"
```

### 1. Start a local registry

```bash
docker run -d --name venafi-demo-registry \
  -p 5001:5000 \
  -e REGISTRY_STORAGE_DELETE_ENABLED=true \
  registry:3

curl -fsS http://localhost:5001/v2/ && echo "registry up"
```

`registry:3` (distribution v3) implements the OCI 1.1 **Referrers API**, which is how a signature
gets attached to and discovered for an image. On an older registry notation falls back to the
referrers *tag* schema — it still works, but that's worth knowing if signatures seem to vanish.

### 2. Build and push the image

```bash
docker build -t "$IMAGE" "$DEMO_DIR"
docker push "$IMAGE"
```

### 3. Capture the digest

```bash
export IMAGE_DIGEST="$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE")"
echo "$IMAGE_DIGEST"
# localhost:5001/venafi-demo@sha256:1a2b3c...
```

Two rules, both load-bearing:

**Push before sign, always.** A signature is an OCI artifact whose *subject* is the image manifest
in the registry. There's nothing to attach a signature to until the image exists remotely —
`notation sign` resolves the reference over the network and writes there.

**Sign the digest, never the tag.** A tag can be repointed after you've checked the image, so
you'd be signing bytes nobody reviewed.

### 4. Install the notation CLI

```bash
# macOS
brew install notation

# Linux (or macOS without brew) — confirm the asset name on the release page first
NOTATION_VERSION=1.3.2
curl -fsSL -o notation.tar.gz \
  "https://github.com/notaryproject/notation/releases/download/v${NOTATION_VERSION}/notation_${NOTATION_VERSION}_linux_amd64.tar.gz"
tar -xzf notation.tar.gz notation && sudo mv notation /usr/local/bin/

notation version
```

v1.3.2 is the version the Venafi plugin is tested against. Asset names follow
`notation_<version>_<os>_<arch>.tar.gz`; check the
[release page](https://github.com/notaryproject/notation/releases) if the download 404s.

### 5. Allow the plain-HTTP local registry

Notation refuses non-TLS registries unless you allowlist them. Real registries need none of this.

```bash
mkdir -p "$NOTATION_DIR"
# WARNING: overwrites config.json. Back it up first if you already use notation.
cat > "$NOTATION_DIR/config.json" <<JSON
{
    "insecureRegistries": ["localhost:5001"]
}
JSON
```

---

## Option 1 — self-signed CA

Keys on disk. No external services.

### 1.1 Generate the PKI

```bash
./gen-signing-certs.sh
export PKI="$DEMO_DIR/pki"
ls "$PKI"
```

Three tiers:

```
root CA (10y)  ->  intermediate CA (5y)  ->  signing leaf (365d)
```

| File | What it is |
|---|---|
| `root.crt` | **the trust anchor** — the certificate a verifier is given |
| `intermediate.crt` | issuing CA, travels in the chain |
| `signing.crt` / `signing.key` | the leaf and **its private key, sitting on your filesystem** |
| `signing-chain.crt` | leaf + intermediate + root concatenated — **this is what you sign with** |

Read the `CHAIN LIFETIMES` block it prints. The number that matters is the **effective** lifetime
— the earliest expiry anywhere in the chain, not the leaf's. Issuing a 365-day leaf from an
intermediate with 200 days left gives you signatures that die in 200 days while the certificate
still reads a year. The script refuses to do that silently; `--help` explains the clamp.

Now inspect the leaf profile, because this is exactly what you'd ask a PKI team to reproduce:

```bash
openssl x509 -in "$PKI/signing.crt" -noout -text \
  | grep -A2 "Basic Constraints\|Key Usage\|Extended Key Usage"
openssl x509 -in "$PKI/signing.crt" -noout -subject
```

You should see:

```
X509v3 Basic Constraints: critical
    CA:FALSE
X509v3 Key Usage: critical
    Digital Signature
X509v3 Extended Key Usage:
    Code Signing

subject=C = US, ST = WA, O = ExampleOrg, OU = Platform-Unikube, CN = unikube-image-signer
```

`CA:FALSE`, `Digital Signature` only, `Code Signing` — and crucially **no** `TLS Web Server
Authentication`. That last point is why an ordinary web-server certificate template can't be
reused for image signing: `serverAuth` in the EKU fails the Notary leaf profile.

The full DN matters too. A leaf carrying only `CN` and `O` can't be pinned by a valid
`trustedIdentities` policy later — see [1.5](#15-verify).

### 1.2 Register the key with notation

`notation key add` handles **plugin** keys only — the CLI has no subcommand for on-disk key/cert
pairs. You register those by writing `signingkeys.json` directly, and it takes **absolute paths**:

```bash
cat > "$NOTATION_DIR/signingkeys.json" <<JSON
{
    "default": "local-signer",
    "keys": [
        {
            "name": "local-signer",
            "keyPath": "${PKI}/signing.key",
            "certPath": "${PKI}/signing-chain.crt"
        }
    ]
}
JSON

notation key ls
```

**`certPath` must be `signing-chain.crt`, not `signing.crt`.** The Notary spec requires the
envelope to carry the complete chain terminating at the root. A bare leaf signs without complaint
and then fails verification — a green build and a rejected pod.

### 1.3 Sign

```bash
notation sign --signature-format cose --key local-signer "$IMAGE_DIGEST"
notation ls "$IMAGE_DIGEST"
```

### 1.4 Inspect the signature

```bash
notation inspect "$IMAGE_DIGEST"
```

Look at the `certificates` list — **three** entries: leaf, intermediate, root. Remember what this
looks like; in Option 2 it becomes the test that matters most.

### 1.5 Verify

```bash
notation certificate add --type ca --store demo-local "$PKI/root.crt"

cat > "$DEMO_DIR/trustpolicy.json" <<'JSON'
{
    "version": "1.0",
    "trustPolicies": [
        {
            "name": "demo-local",
            "registryScopes": [ "*" ],
            "signatureVerification": { "level": "strict" },
            "trustStores": [ "ca:demo-local" ],
            "trustedIdentities": [ "*" ]
        }
    ]
}
JSON

notation policy import --force "$DEMO_DIR/trustpolicy.json"
notation verify "$IMAGE_DIGEST"
```

Verify against the **root**, not the intermediate — the root is what a verifier holds.

Note `trustedIdentities: ["*"]`. Per the Notary spec that means *"any signing certificate issued
by a CA in the trust store is allowed"*. **This is the only mode Wiz can express.** Sections 1.6
and 1.7 show why that matters.

### 1.6 A second image, signed by a second leaf

Mint a signing certificate for a *different team*, from the same intermediate:

```bash
./gen-signing-certs.sh --second-leaf
openssl x509 -in "$PKI/signing-team-b.crt" -noout -subject
# subject=C = US, ST = WA, O = ExampleOrg, OU = Other-Team, CN = other-team-signer
```

Nothing here is a misconfiguration — issuing certificates to multiple teams is what a shared CA is
*for*. Confirm both leaves are legitimately issued under the same root:

```bash
openssl verify -CAfile "$PKI/root.crt" -untrusted "$PKI/intermediate.crt" \
  "$PKI/signing.crt" "$PKI/signing-team-b.crt"
# signing.crt: OK
# signing-team-b.crt: OK
```

Build and push a second, genuinely different image:

```bash
docker build --build-arg VARIANT=b -t "${REGISTRY}/venafi-demo:v2" "$DEMO_DIR"
docker push "${REGISTRY}/venafi-demo:v2"
export IMAGE_B_DIGEST="$(docker inspect --format='{{index .RepoDigests 0}}' "${REGISTRY}/venafi-demo:v2")"
echo "$IMAGE_B_DIGEST"
```

Register the second key alongside the first — note `signingkeys.json` holds a **list**:

```bash
cat > "$NOTATION_DIR/signingkeys.json" <<JSON
{
    "default": "local-signer",
    "keys": [
        {
            "name": "local-signer",
            "keyPath": "${PKI}/signing.key",
            "certPath": "${PKI}/signing-chain.crt"
        },
        {
            "name": "team-b-signer",
            "keyPath": "${PKI}/signing-team-b.key",
            "certPath": "${PKI}/signing-team-b-chain.crt"
        }
    ]
}
JSON

notation key ls
```

Sign the second image with the second leaf, and verify both:

```bash
notation sign --signature-format cose --key team-b-signer "$IMAGE_B_DIGEST"

notation verify "$IMAGE_DIGEST"      # signed by Platform-Unikube
notation verify "$IMAGE_B_DIGEST"    # signed by Other-Team
```

**Both pass.** You now have two signed images, signed by two different teams' certificates, and
the verifier accepts both — because the only question it was asked is *"does this chain terminate
in root.crt?"*, and for both of them it does.

### 1.7 Now pin the signer — and see what Wiz can't do

Edit `trustpolicy.json` and replace `"trustedIdentities": [ "*" ]` with:

```json
"trustedIdentities": [ "x509.subject: C=US, ST=WA, O=ExampleOrg, OU=Platform-Unikube" ]
```

```bash
notation policy import --force "$DEMO_DIR/trustpolicy.json"

notation verify "$IMAGE_DIGEST"      # PASSES — OU matches
notation verify "$IMAGE_B_DIGEST"    # FAILS  — signing certificate not in trusted identities
```

That second failure is the control we want, and **Wiz does not implement it.** Its image-integrity
validator takes a certificate and nothing else — there is no `trustedIdentities` equivalent, so it
is permanently in the `"*"` mode of 1.6, where both images are admitted.

This is the whole reason the trust anchor has to be a CA used for *nothing but* image signing. Put
a general-purpose corporate root in there and every team holding a code-signing certificate from
it becomes able to get images admitted fleet-wide — the situation you just reproduced in 1.6, at
company scale.

Two details worth noting while you're here:

- Pin at **`OU`, not `CN`**. The annual leaf rotation changes the CN; pinning there would mean a
  policy change every year. Partial DNs match, so `OU` is the stable handle.
- The entry must contain at least `C`, `ST` (or `S`) and `O`. A leaf issued with only `CN` and `O`
  **cannot be pinned by a valid policy at all** — which is why `gen-signing-certs.sh` issues a
  full DN even though Wiz ignores it today.

### 1.8 What you just proved, and the problem with it

Two things.

**The anchor is the boundary.** Anything chaining to `root.crt` is admitted, and the only way to
narrow that is a field Wiz doesn't have. So the anchor must be dedicated.

**The key is a liability.** `signing.key` and `signing-team-b.key` are sitting in `./pki/`,
readable by you, and in CI they'd be secrets pasted into environment variables. Anyone who obtains
one can sign anything the admission controller will accept, fleet-wide, for up to 365 days, with
no audit trail and no way to revoke.

Option 2 fixes the second problem. **It does not fix the first** — only a dedicated root does
that.

---

## Option 2 — Venafi CodeSign Protect

Same image, same `notation sign` command. The difference is that **no private key ever exists on
this machine** — signing becomes an API call to Venafi, which signs inside its HSM.

### 2.1 What you have, and what's still missing

What the PKI team has provided:

| Given | Value | Maps to |
|---|---|---|
| Code signing project + certificate | `TeamImageSigning` | `tpp_project` and the key label — **but see below** |
| Credentials | username + password | must be **exchanged for an access token** — see [2.3](#23-exchange-your-password-for-an-access-token) |
| API host | `codesigningapi.test.org` | `tpp_url` |
| Tooling hint | "use `pkcs11config`" | the CodeSign Protect client — see [2.2](#22-install-the-client-tools) |
| Environment | **staging** | not production; see [2.11](#211-staging-is-not-production) |

**Four things are still missing, and three of them block signing.**

| # | Missing | Why it blocks | Ask |
|---|---|---|---|
| 1 | The **`vsign-sdk` API Integration**, with your user assigned to it | No API Integration means no token, whatever your password is. Minimum scopes for TPP ≥ 23.x are `codesignclient;codesign`; vSign also wants `certificate:manage,discover` to retrieve signing certificates. | "Please create the `vsign-sdk` API Integration and assign our code signing user to it, with scope `codesignclient;codesign;certificate:manage,discover`." |
| 2 | The exact **`Project\Environment`** path | `TeamImageSigning` is one name, but `tpp_project` needs *two* — the config value is literally `Project\Environment`. It's unclear whether that's the project, the environment, or the certificate label. | "What is the full `Project\Environment` path, and what is the certificate label on the environment?" |
| 3 | The **root CA certificate** (and chain) | This is what the admission controller is given. Without it nothing can be verified — and nobody mentioned handing it over. | "Please send the root CA certificate for the hierarchy that issued this signing certificate." |
| 4 | **Which CA issued it** — dedicated hierarchy, or the corporate root? | Doesn't block signing. Decides whether this design is sound at all — see [1.7](#17-now-pin-the-signer--and-see-what-wiz-cant-do). | You can answer this yourself in [2.4](#24-find-the-environment-path-and-inspect-the-certificate). |

Item 4 is the one to care about. Sections 1.6–1.7 exist to explain why: if `TeamImageSigning` was
issued under a general-purpose corporate root, then every other code-signing certificate in the
company is also a fleet-wide admission credential, and no amount of Venafi configuration fixes it.

The remaining prerequisites from the original design — Flow with no approval action, timestamping
off, leaf profile, key type, validity, IP restrictions — are all checkable once you can
authenticate. [2.10](#210-the-checklist-you-can-now-run-yourself) turns them into commands.

### 2.2 Install the client tools

`pkcs11config` ships with the **CodeSign Protect client**, which is a separate download from the
Venafi server — not part of notation. Ask for the Linux/macOS client package, or fetch it from the
TPP web UI.

> **Worth clarifying with them:** `pkcs11config` belongs to the **PKCS#11** driver path. The
> notation plugin does *not* use PKCS#11 — it talks to the REST API through the vSign SDK. So you
> need `pkcs11config` only to *discover* the certificate label. If they intended PKCS#11-based
> signing, that's a different integration than this one, worth resolving before you build anything.

You'll also want the `vsign` CLI, which is the easiest way to turn a password into a token:

```bash
go install github.com/venafi/vsign/cmd/vsign@latest
# or clone and `make vsign`
```

### 2.3 Exchange your password for an access token

The plugin's `config.ini` takes an `access_token`, not a username and password. Two ways to get
one.

**With the vsign CLI:**

```bash
export TPP_URL='https://codesigningapi.test.org'

vsign getcred --url "$TPP_URL" --username 'your-user' --password 'your-password'
# access_token: P1sfL7l4uCWwH/zMkJY7IA==

export TPP_ACCESS_TOKEN='P1sfL7l4uCWwH/zMkJY7IA=='
```

**Or straight against the API:**

```bash
curl -sS -X POST "${TPP_URL}/vedauth/authorize/oauth" \
  -H 'Content-Type: application/json' \
  -d '{
        "client_id": "vsign-sdk",
        "username":  "your-user",
        "password":  "your-password",
        "scope":     "codesignclient;codesign;certificate:manage,discover"
      }'
```

You get back `access_token`, `refresh_token`, `expires` and the granted `scope`. Check the scope
in the response actually contains what you asked for — a narrower grant is how missing-permission
errors show up three steps later.

Three things that commonly go wrong here:

- **`client_id` must match a real API Integration.** If `vsign-sdk` doesn't exist, or your user
  isn't assigned to it, you get an error rather than a token. That's missing item 1.
- **Username format.** Local TPP identities are often `local:your-user`; AD identities are the
  bare name or `domain\user`. If authentication fails with credentials you know are right, this is
  usually why.
- **TLS trust.** `codesigningapi.test.org` is an internal staging host, so its TLS certificate is
  probably issued by an internal CA your laptop doesn't trust yet. vSign takes a
  `trust_bundle` config option (`VSIGN_TRUST_BUNDLE`) pointing at that chain — not to be confused
  with the code-signing chain from missing item 3. They're different certificates for different
  purposes.

**Tokens expire.** For CI later, don't store a long-lived one: vSign supports `jwt`/`VSIGN_JWT`,
which exchanges a short-lived OIDC token for a short-lived TPP access token — exactly what you'd
want from GitHub Actions OIDC. Worth confirming JWT authentication is enabled on this server
(it needs TPP 22.4+).

### 2.4 Find the environment path and inspect the certificate

```bash
pkcs11config getcertificate --help      # flags vary by client version
```

Use it to list what your user can reach and read back the certificate label. You need two values:
the full `Project\Environment` path, and the label. If they differ from `TeamImageSigning`, that
resolves missing item 2.

**Then answer missing item 4.** Save the certificate and read its issuer chain:

```bash
openssl x509 -in TeamImageSigning.crt -noout -issuer -subject -dates
openssl x509 -in TeamImageSigning.crt -noout -text \
  | grep -A2 "Basic Constraints\|Key Usage\|Extended Key Usage"
```

Compare against the profile you produced in [1.1](#11-generate-the-pki):

| Check | Want | If not |
|---|---|---|
| `Extended Key Usage` | `Code Signing` **only** | `serverAuth` present → TLS template was used, verification will fail |
| `Key Usage` | `Digital Signature` | `keyCertSign` present → wrong profile |
| `Basic Constraints` | `CA:FALSE` | a CA certificate cannot be a signing certificate |
| Subject DN | `C`, `ST`, `O`, `OU` all present | can't be pinned by a valid policy later |
| `notAfter` | ~365 days | much shorter means re-signing everything that often |
| **Issuer chain** | a root used **only** for code signing | the corporate root → see [1.7](#17-now-pin-the-signer--and-see-what-wiz-cant-do); escalate |

### 2.5 Install the plugin

```bash
notation plugin install \
  --url https://github.com/Venafi/notation-venafi-csp/releases/download/v0.3.0/notation-venafi-csp-linux-amd64.tar.gz \
  --sha256sum 03771794643f18c286b6db3a25a4d0b8e7c401e685b1e95a19f03c9356344f5a

notation plugin ls
```

That hash is for **linux-amd64 v0.3.0** — the only one published in the vendor README. For macOS
(`-darwin-arm64`, `-darwin-amd64`) take the hash from the
[release page](https://github.com/Venafi/notation-venafi-csp/releases).

> In CI, don't pull this from GitHub on every build. Mirror the binary internally and pin the
> hash — it's a new dependency inside the signing path.

### 2.6 Write config.ini

```bash
export TPP_PROJECT='TeamImageSigning\<environment>'   # confirm in 2.4
export CERT_LABEL='TeamImageSigning'                  # confirm in 2.4

umask 077
cat > "$DEMO_DIR/config.ini" <<INI
tpp_url = ${TPP_URL}
access_token = ${TPP_ACCESS_TOKEN}
tpp_project = ${TPP_PROJECT}
INI
chmod 600 "$DEMO_DIR/config.ini"
```

**`tpp_url` is the base URL** — `https://codesigningapi.test.org`, with no path suffix. The SDK
appends `/vedauth` and `/vedsdk` itself.

If TLS to that host fails, add the internal CA chain:

```ini
trust_bundle = /path/to/internal-ca-chain.pem
```

This file carries a bearer token — treat it like a private key. In CI it belongs in a `mktemp -d`
with a `trap` cleanup.

### 2.7 Register the remote key

```bash
notation key add --default "$CERT_LABEL" \
  --plugin venafi-csp \
  --id "$CERT_LABEL" \
  --plugin-config "config=$DEMO_DIR/config.ini"

notation key ls
```

Compare with [1.2](#12-register-the-key-with-notation): no `keyPath`, no `certPath`, no
`signingkeys.json`. There is nothing on disk to point at.

### 2.8 Sign

```bash
notation sign --signature-format cose --key "$CERT_LABEL" "$IMAGE_DIGEST"
notation ls "$IMAGE_DIGEST"
```

Identical to Option 1's command. If it fails, in rough order of likelihood:

| Symptom | Cause |
|---|---|
| hangs, or "pending approval" | the Environment's Flow has an approval action — no-approval Flow needed for CI |
| 401 / unauthorized | token expired, or scope too narrow — recheck the granted scope from 2.3 |
| "signing key not found" | `tpp_project` path or `CERT_LABEL` wrong — back to 2.4 |
| x509 / TLS error | internal CA not trusted — set `trust_bundle` |
| forbidden from this address | your IP is outside the Environment's permitted range |
| refuses the registry | `localhost:5001` not allowlisted — redo prerequisite 5 |

### 2.9 Inspect — the test that matters

```bash
notation inspect "$IMAGE_DIGEST"
```

Count the `certificates` entries. In Option 1 you controlled the chain file directly, so three was
guaranteed. Here the chain comes from whatever the CodeSign Protect environment holds, and **the
vendor docs don't state whether that's the full chain or a bare leaf**.

**One entry = bare leaf = stop.** Signing succeeded, the admission controller will reject the
image, and you'd only find out on a cluster. Fix the environment before wiring any pipeline.

### 2.10 The checklist you can now run yourself

Once 2.3 works, these stop being questions for the PKI team and become commands:

| Question | How to answer it |
|---|---|
| Dedicated hierarchy or corporate root? | `openssl x509 -noout -issuer` on the cert, then walk the chain (2.4) |
| Right leaf profile? | `openssl x509 -noout -text` (2.4) |
| Key type supported by the plugin? | RSA 2048/3072/4096 or EC 256/384/521 — **not** Ed25519, **not** RSA-8192 |
| Certificate validity? | `openssl x509 -noout -dates` |
| Full chain or bare leaf? | `notation inspect` (2.9) |
| Does the Flow block automation? | 2.8 either returns or hangs |
| Is my IP allowed? | 2.8 returns a forbidden error if not |
| Is timestamping off? | `notation inspect` — a timestamped signature shows a timestamp attribute |

### 2.11 Staging is not production

You have a **staging** environment, which is the right place to start — but two consequences:

- The staging root is **not** the production trust anchor. Don't put it anywhere near the
  production admission controller: it would make every staging-signed image admissible in prod.
- Everything in 2.1 has to happen again for production, on a *different* hierarchy. Get the
  answers to items 1–4 now, while it's cheap, so the production request is a known quantity rather
  than a rediscovery.

Worth asking now: **will the production hierarchy be structured the same way as staging?** If
staging was quietly issued under the corporate root because it's "only staging", production may
default to the same thing.

### 2.12 The two-signer problem, restated for Venafi

Section 1.6 has a direct equivalent here, and it's the thing to keep in mind when the PKI team
offers to reuse an existing hierarchy: **a second CodeSign Protect Environment, under the same CA,
produces a second leaf that chains to the same root.** Everything about it is legitimate, and the
admission controller will admit its signatures exactly as it admits yours.

Venafi *can* constrain who signs — key custody in the HSM, the Flow, per-environment IP
restrictions, the permitted-applications list. But every one of those is enforced at **signing
time by Venafi**, on our signing path. The admission controller enforces one thing at **admission
time**: does the chain terminate in the anchor. A control on the wrong side of that line cannot
narrow what gets admitted.

Which is why the dedicated hierarchy — missing item 4 in [2.1](#21-what-you-have-and-whats-still-missing)
— is not optional detail. It is the only part of this design that constrains anyone other than us.

---

## What changed between the two options

| | Option 1 — self-signed | Option 2 — Venafi |
|---|---|---|
| Private key location | your filesystem / a CI secret | HSM, non-exportable |
| Key registration | hand-written `signingkeys.json` | `notation key add --plugin` |
| Credential on the machine | the key itself | a scoped, revocable token |
| Who can sign | anyone who reads the file | the identity the Flow permits, from a permitted IP |
| Audit | none | every signing operation recorded |
| Rotation | regenerate, paste a new secret | certificate renewal in TPP, no secret to update |
| `notation sign` command | **identical** | **identical** |

That last row is why the migration is small: everything changes *behind* the sign call.

## Cleanup

```bash
docker rm -f venafi-demo-registry
notation key delete local-signer team-b-signer 2>/dev/null
notation key delete "$CERT_LABEL" 2>/dev/null
notation certificate delete --type ca --store demo-local --all -y 2>/dev/null
rm -rf "$DEMO_DIR/pki" "$DEMO_DIR/config.ini" "$DEMO_DIR/trustpolicy.json"
```

`./pki/` holds private keys in the clear and is gitignored. Don't commit it, and don't reuse those
certificates for anything real.

## Not covered here

**Whether the image should be signed at all.** In the real pipeline an image must pass a
vulnerability/compliance check before it's signed — signing is the *reward* for compliance, not a
step everything gets. The `Dockerfile` here is `FROM alpine`; it exists only to have something
with a digest.

**What the admission controller actually concludes.** `notation verify` proves what *Notation*
concludes. Wiz's own trust policy isn't ours to inspect, and `trustedIdentities` has no Wiz
equivalent. A local pass means the chain and the expiry are sound — most of what goes wrong, but
not all of it.
