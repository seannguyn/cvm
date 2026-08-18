# Using `notation` with Venafi TPP — Comprehensive Tutorial

A full walkthrough of wiring `notation` (the Notary Project CLI) to Venafi TPP for signing OCI/container images.

---

## Do you create a dedicated CA in TPP?

**No — not a CA in the "stand up a new certificate authority" sense.**

What you create in TPP is a **CodeSign Protect Project + Certificate Environment**. That environment produces the signing key (in the HSM) and a signing certificate. The certificate itself is *issued* by whatever CA the environment's policy points at, and that can be:

- an existing internal/enterprise CA you already run (MS ADCS, etc.),

<user_response> 
We are configuring Wiz admission controller to verify images via Notation. You can only put trust anchor, root CA on Wiz.

What if we configure org root CA, then other teams who have permission to request certifcates and keys from this root CA in venafi. They use this certificate and key to sign their container images.

If this is the case, then we should use a dedicated self-signed root on Venafi that only our team and platform team has permission to request certificates and keys from this root CA? right?
<user_response>

- a public CA connector, or
- a self-signed root, which is perfectly fine for internal image signing where you control both signer and verifier.

Notation's trust model doesn't care that Venafi issued anything. It cares about the **certificate chain**: you register the signing cert's CA/root into notation's trust store and reference it in the trust policy. So the mental model is *"create a signing environment whose cert chain I can hand to notation,"* not *"create a CA."* If you already have a code-signing environment in TPP, you reuse it — no new CA needed.

> **Naming note:** Venafi CodeSign Protect is now branded **CyberArk Code Sign Manager**, and on-prem TPP is "Self-Hosted." The plugin currently requires **TPP/TPF 23.1+** for the full feature set. Older docs say "TPP"; newer ones say "Code Sign Manager, Self-Hosted." Same product line.

---

## How the pieces fit

The plugin is `notation-venafi-csp`, which shells out through Venafi's **vSign SDK** to talk to TPP. It's a Notary Project plugin that supports the JWS and COSE Sign1 signature envelope formats, key specs from RSA-2048 through EC-521, and the `notary.x509` signing scheme. The key and cert live in TPP/HSM; the plugin never sees private key material — it asks TPP to sign a digest.

---

## Prerequisites in TPP

1. CodeSign Protect module enabled, with an HSM provisioned.
2. A **Code Signing Project** containing a **Certificate Environment** (this is the object that yields your signing cert + key). Note the environment/label name — you'll need it.
3. An **API integration / OAuth application** so you can mint an access token (grant it the code-signing scope).
4. Your user granted rights to that signing environment.

---

## Step 1 — Install the CLI and plugin

Install `notation` itself first (v1.3.2 is the tested version), then install the plugin:

```bash
notation plugin install \
  --url https://github.com/Venafi/notation-venafi-csp/releases/download/v0.3.0/notation-venafi-csp-linux-amd64.tar.gz \
  --sha256sum <sha256-from-the-release-page>
```

Adjust the URL and sha256sum to match the release and platform you're deploying. Building from source (`git clone`, `make build`, `make install`) also works, but the Makefile's `make install` assumes a macOS plugin directory layout, so edit it for your OS.

---

## Step 2 — Create the vSign config.ini

This file is how the plugin reaches TPP. The three fields you customize are `tpp_url`, `access_token`, and `tpp_project`:

```ini
tpp_url = https://tpp.yourcompany.com/vedsdk
access_token = <oauth-access-token>
tpp_project = "MyProject\MyCertEnvironment"
```

The `tpp_project` value is the `Project\Environment` path from step 2 of the prerequisites. Protect this file — the access token is a bearer credential. In CI, prefer minting the token at runtime over baking it in.

---

## Step 3 — Get the certificate label and register the key

Pull the cert label that matches your environment via `pkcs11config getcertificate`, then register it with notation. A good convention is to name the notation key ID after the CodeSign Protect environment's certificate label:

```bash
notation key add --default "vsign-rsa2048-cert" \
  --plugin venafi-csp \
  --id "vsign-rsa2048-cert" \
  --plugin-config "config"="/path/to/vsign/config.ini"

notation certificate add --type ca --store example.com /path/to/chain.crt
```

Confirm with `notation key list` and `notation certificate list`.

---

## Step 4 — Sign

```bash
IMAGE=localhost:5001/net-monitor@sha256:<digest>
notation sign --key "vsign-rsa2048-cert" $IMAGE
```

Always sign by **digest**, not tag — a tag can be re-pointed after signing. `notation ls $IMAGE` should now show one `application/vnd.cncf.notary.v2.signature` entry.

---

## Step 5 — Trust policy and verify

Create `trustpolicy.json`, referencing the trust store you populated in step 3:

```json
{
  "version": "1.0",
  "trustPolicies": [{
    "name": "wabbit-networks-images",
    "registryScopes": [ "*" ],
    "signatureVerification": { "level": "strict" },
    "trustStores": [ "ca:example.com" ],
    "trustedIdentities": [ "*" ]
  }]
}
```

Import and verify:

```bash
notation policy import ./trustpolicy.json
notation verify $IMAGE
```

Tighten `trustedIdentities` from `*` to specific certificate subjects (e.g. `x509.subject: CN=...`) once you're past testing.

---

## Gotchas worth knowing

- **Verification does an extra live check.** On TPF 23.1+, verification also validates via PKS that the certificate still exists in Code Sign Manager, using the experimental `com.venafi.notation.plugin.x5u` extended attribute for identity validation. That means verification can touch TPP, not just your local trust store — plan network access for verifiers accordingly.
- **Timestamping.** Notation supports RFC 3161 timestamping (`notation sign --timestamp-url ... --timestamp-root-cert ...`). Use it, or signatures stop verifying once the signing cert expires.
- **Registry must support referrers.** Signatures attach as OCI referrer artifacts; an old registry without referrers-API support will reject the push.
- **Separate prod and non-prod** into different environments/HSM partitions, and give each pipeline its own service identity rather than sharing one token — it audits far better.

---

## Reference

- `notation-venafi-csp` plugin: https://github.com/Venafi/notation-venafi-csp
- vSign SDK: https://github.com/Venafi/vsign
- Notation CLI: https://github.com/notaryproject/notation
- Notary Project trust policy guide: https://notaryproject.dev/docs/user-guides/how-to/manage-trust-policy/
