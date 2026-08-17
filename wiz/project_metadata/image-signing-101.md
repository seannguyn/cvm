# Image labels, digests, cosign & attestation — a 101

> This is the conceptual primer. For the Notation **operational** detail — what each
> verification level enforces, why our PKI has three tiers, rotation deadlines, and what a
> leaked key at each tier buys an attacker — see [`notation-signing.md`](notation-signing.md).

A from-scratch explainer for the trust model behind the compliance workflow. Read top to
bottom; each section builds on the last. The punchline: **trust digests and signatures,
never labels.**

---

## 1. The container image, briefly

An OCI image is content-addressed. Three layers of identity:

- **Layers** — the filesystem, as a stack of tarballs. Each has a `diff_id` = sha256 of
  its content. You cannot change a layer's bytes without changing its `diff_id`.
- **Config** — JSON describing the image: env vars, entrypoint, `.Created` timestamp,
  the ordered list of layer `diff_ids`, and **labels**. The config has its own digest.
- **Manifest** — points at the config digest + the layer digests. **The image digest**
  (`sha256:…`, what you see in `image@sha256:…`) is the digest of the manifest.

Key consequence: a **tag** (`alpine:3.20`) is a mutable pointer that can be moved to a
different digest at any time. A **digest** (`alpine@sha256:…`) is immutable — it always
refers to the exact same bytes. **Pin to digests for anything security-relevant.**

---

## 2. Labels — convenient, and NOT trustworthy

A `LABEL` in a Dockerfile is just a key/value written into the config by **whoever builds
the image**. Examples you'll see: `org.opencontainers.image.source`,
`org.opencontainers.image.base.name`, `org.opencontainers.image.base.digest`.

Your earlier question was: *"if labels are part of the config, and the config is part of
the digest, then labels are 'in' the digest — so aren't they trustworthy?"*

Both halves are true and it still doesn't help you:

- Yes — labels are in the config, so they contribute to the image digest. Changing a
  label changes the digest. In that narrow sense labels are "immutable per digest."
- **But the label VALUES are chosen freely by the image author.** A tenant can write
  `LABEL org.opencontainers.image.base.name=container-soe.registry.domain/alpine`
  while actually building `FROM docker.io/evil`. The label is a valid part of *that*
  image's digest — and a **lie**. Nothing stops them.

So: a digest guarantees *integrity* ("these exact bytes, including these labels"). It does
**not** guarantee the label's *claim* is true. Never gate admission on a label's value.

**The unforgeable signal is layer identity.** A built image physically contains its base
image's layers as its lower layers. Those `diff_ids` are content-addressed, so you cannot
reproduce them without actually building on that base. To verify "this image is built on an
approved base," resolve the approved base to a digest, read its layer `diff_ids`, and
confirm the built image's lower layers equal them. That's exactly what the compliance step
does (`docker inspect` the layers), and why it ignores labels.

---

## 2b. This project uses NOTATION (Notary v2), not cosign — and why

This is an **air-gapped, internal-enterprise** setup with a **CA + private key + signing
certificate** (no internet, so Sigstore's keyless/Fulcio/Rekor is out). For that,
**Notation (the Notary Project v2)** is the right tool:

- It's built around **X.509 PKI**: a CA issues signing certs, verifiers carry a **trust
  store** of CA certs and a **trust policy** — no external transparency log required.
- Keys live behind a **plugin** to an HSM/KMS/Vault (enterprise key custody).
- Signatures are OCI artifacts attached via the **referrers API (ORAS)** — fully offline.

In this repo: Wiz's **shared image-integrity validator** is configured with `method = NOTARY`
and the **CA certificates** as its trust roots (terraform var `notary_ca_certificates`, a
list rendered from every `trust/*.crt`). The
unikube workflow runs `notation sign` on compliant images; Wiz verifies the Notation
signature at admission. `scripts/gen_signing_certs.sh` produces a local test CA + signing
cert (openssl). Everything in §3–§6 below (cosign) is background/comparison — the *mechanism*
(sign → attach → verify identity/trust) is the same; only the trust root differs (a CA you
run, vs. Sigstore's public CA).

### Cert expiry = revocation (important)

Because admission depends on the signing cert chaining to the trusted CA, **when the signing
certificate expires, images signed by it stop being admissible** — a coarse, fleet-wide
revocation. This only holds if you do **NOT** use trusted **timestamping** (RFC 3161): a
timestamped signature stays valid *after* cert expiry (it proves "signed while valid"), which
is the opposite of what we want here. So: don't timestamp, or set the Notation **trust policy
to require certificate validity at verification time**, and keep the signing-cert lifetime
short. To revoke a *single* image (not all images from a cert) you need a deny rule / re-sign.

---

## 3. Signing (cosign, keyless)

Signing answers a different question: *"who produced this image/statement, and has it been
tampered with since?"*

- **cosign** (part of Sigstore) signs OCI artifacts. **Keyless** mode means no private
  keys to manage: in GitHub Actions the workflow has an **OIDC identity** — it can prove
  "I am the workflow `.github/workflows/deploy.yaml` of `org/self-built-image` at commit
  X." cosign exchanges that OIDC token for a **short-lived signing certificate** from
  Sigstore's CA (Fulcio), signs, and the certificate + signature are recorded in a public
  **transparency log (Rekor)**.
- Later, anyone can verify: the signature is valid, it's in the log, and it was produced by
  **exactly that workflow identity**. An attacker can't forge a signature that verifies
  against your workflow's identity.

```bash
cosign sign --yes "$IMAGE@$DIGEST"          # keyless; identity = the CI workflow (OIDC)
cosign verify "$IMAGE@$DIGEST" \
  --certificate-identity-regexp '^https://github.com/org/self-built-image/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

Signing alone says "this came from us, untampered." It doesn't yet say *anything about
compliance*. For that you need an attestation.

---

## 4. Attestation (in-toto + predicates, incl. SLSA)

An **attestation** is a **signed statement about an artifact**. Format: in-toto — a small
JSON envelope binding a **subject** (the image digest) to a **predicate** (structured
claims). cosign signs and attaches it to the image in the registry (via OCI referrers), so
it travels with the image.

Two predicates matter here:

- **SLSA provenance** — auto-describes *how/where the image was built*: the builder (GitHub
  Actions), source repo, commit, trigger, build parameters. It proves the image came from
  your CI, not someone's laptop. (SLSA = "Supply-chain Levels for Software Artifacts," a
  framework of increasing build-integrity guarantees.)
- **Custom compliance predicate** — your own JSON, e.g.:
  ```json
  {
    "all_from_soe": true,
    "base_images": ["container-soe.registry.domain/alpine@sha256:..."],
    "final_base_fresh": true,
    "checked_at": "2026-07-30T10:00:00Z"
  }
  ```

```bash
cosign attest --yes --type slsaprovenance --predicate provenance.json "$IMAGE@$DIGEST"
cosign attest --yes --type custom          --predicate compliance.json "$IMAGE@$DIGEST"
```

---

## 5. Verification

`cosign verify-attestation` checks three things together:

1. the attestation's **signature** is valid and logged (Rekor),
2. the **signer identity** matches who you expect (the tenant's workflow),
3. the **predicate** satisfies your policy (e.g. `all_from_soe == true`).

```bash
cosign verify-attestation "$IMAGE@$DIGEST" --type custom \
  --certificate-identity-regexp '^https://github.com/org/self-built-image/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --policy compliance.rego     # optional: assert on predicate contents
```

This is exactly what a Kyverno `verifyImages` rule or a Wiz check could enforce at
admission — but even without runtime enforcement, having the signed attestation gives you
durable, auditable proof.

---

## 6. How this project uses it (current model = NOTATION)

The unikube workflow (`.github/workflows/unikube.yaml`) does, per target cluster:

1. **Build.**
2. **Static** base-image check — every `FROM` must be `container-soe.registry.domain/*`.
3. **Authoritative** check — `docker inspect` the built image's base-layer **digests** +
   the final base image's `.Created` (freshness ≤ 30 days). **Digests, not labels.**
   Steps 2 and 3 are both `compliance_check.py`: it shells out to docker itself, so the
   rules live in one place rather than half in a script and half in workflow YAML. If
   docker cannot answer, the verdict is **not compliant** (fail closed) — "compliant" means
   signed and admitted fleet-wide unattended, so it must never be the fallback.

   Note the trust boundary on `.Created`: it is part of the image config, so it is covered
   by the digest and cannot be altered after the fact — but it is chosen by whoever built
   the base. That is acceptable only because bases are restricted to
   `container-soe.registry.domain/*`, i.e. our own SOE team. It would be worthless for a
   third-party base. This is a weaker guarantee than the layer-digest check and a different
   one from "never trust labels" (labels are set by the *tenant*, on their own image).
4. **Branch:**
   - **Compliant** → `docker push`, then `notation sign` the pushed **digest** (NOTARY / CA
     cert). Wiz's shared NOTARY validator verifies the signature at admission → admitted
     **fleet-wide**. No YAML, no PR.
   - **Not compliant** → check every target cluster's already-merged `exemptions` first; all
     match → push (unsigned), else fail before touching the registry.

**Push precedes sign, not the other way round.** A Notation signature is an OCI artifact
stored *in the registry* as a referrer to the image manifest (§2b), so there is nothing to
sign until the image is pushed. The gap is harmless — an unsigned image is simply not
admissible — but it does mean "pushed" never implies "admissible", so a failed signing step
must fail the job loudly. Sign the **digest** returned by the push, not the tag: a tag can
be repointed between the compliance check and the signature.

Admission needs no attestation here — the **signature is the gate** (see §2b). Attestation
(SLSA provenance / a compliance predicate) is optional audit-trail only. The trust root is a
**CA cert** you manage (`notary_ca_certificates`), not Sigstore.

> Mock note: there is no real registry/OIDC in this repo, so the cosign calls in
> `unikube.yaml` are **stubbed** (echo + a placeholder digest). The step order and the
> stored fields are real, so dropping in real cosign is mechanical.

---

## 7. Hands-on — real commands you can run

Tools used below: `docker`, [`crane`](https://github.com/google/go-containerregistry) (works
without a daemon), `skopeo`, `notation` (our signer), `cosign` (background/comparison), `jq`.
§7.1–7.2 (digests/layers) are what our compliance check relies on; §7.3–7.6 (cosign) are
background — our signer is `notation` (§7.7).

### 7.1 Digest, config, layers

```bash
# Pull, then get the immutable repo digest (what you should pin to, not the tag)
docker pull alpine:3.20
docker inspect --format '{{index .RepoDigests 0}}' alpine:3.20
#   alpine@sha256:<64hex>

# Layer identities (diff_ids) and the created timestamp (used for the freshness check)
docker inspect --format '{{json .RootFS.Layers}}' alpine:3.20 | jq .
docker inspect --format '{{.Created}}' alpine:3.20

# Same, WITHOUT a docker daemon, straight from the registry (crane):
crane digest alpine:3.20                       # the manifest digest
crane manifest alpine:3.20 | jq '.config.digest, .layers[].digest'
crane config  alpine:3.20 | jq '{created, diff_ids: .rootfs.diff_ids, labels: .config.Labels}'

# skopeo equivalent
skopeo inspect docker://alpine:3.20 | jq '{Digest, Created, Labels}'
```

Note `.config.Labels` may contain `org.opencontainers.image.base.name` /
`...base.digest` — these are **labels** (author-set, see §2). Read them for convenience,
never trust them for the decision.

### 7.2 Prove an image was built on an approved base (layer comparison — the trustworthy check)

A built image's lower layers ARE the base image's layers. Compare `diff_ids`:

```bash
BASE="container-soe.registry.domain/alpine:3.20"
IMG="ecr/tenant_Y_image:1.0.0"

crane config "$BASE" | jq -r '.rootfs.diff_ids[]' > base_layers.txt
crane config "$IMG"  | jq -r '.rootfs.diff_ids[]' > img_layers.txt

# The base's diff_ids must be a PREFIX of the built image's diff_ids:
if head -n "$(wc -l < base_layers.txt)" img_layers.txt | diff -q - base_layers.txt >/dev/null; then
  echo "OK: $IMG is built on $BASE (layers match)"
else
  echo "FAIL: base layers not found at the bottom of $IMG"
fi
```

This cannot be faked without actually building on `$BASE` — unlike a `LABEL` that merely
*claims* the base.

### 7.3 See what's attached to an image (signatures, attestations, SBOMs)

```bash
cosign tree registry.k8s.io/kube-apiserver-amd64:v1.35.0
# └── 💾 Attestations / 🔐 Signatures / 📦 SBOMs attached to the image digest
```

### 7.4 Verify a signature — real, working example (Kubernetes)

Kubernetes release images are cosign **keyless**-signed. Cosign 2.x requires you to state
*who* you expect to have signed (`--certificate-identity`) and *which* OIDC issuer:

```bash
cosign verify registry.k8s.io/kube-apiserver-amd64:v1.35.0 \
  --certificate-identity krel-trust@k8s-releng-prod.iam.gserviceaccount.com \
  --certificate-oidc-issuer https://accounts.google.com | jq .
```

If you omit the identity flags (or point them at the wrong signer) verification **fails** —
that's the point: "signed" is meaningless without "signed *by whom*".

### 7.5 Verify an image signed by a GitHub Actions workflow (identity = a repo/workflow)

For images signed keyless from GitHub Actions (the model our `unikube.yaml` uses), the
identity is the workflow URL and the issuer is GitHub's OIDC:

```bash
# Example shape — confirm the exact identity from the publisher's docs (it changes over time)
cosign verify ghcr.io/<org>/<image>:<tag> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/<org>/<repo>/\.github/workflows/.*@refs/tags/.*'
```

That `--certificate-identity-regexp` is exactly how you'd pin "must be signed by
`org/self-built-image`'s release workflow" — the check at the heart of our compliance model.

### 7.6 Read the attestation predicate (the actual claims)

```bash
# Download attestations and pull out the predicate (e.g. SLSA provenance)
cosign download attestation registry.k8s.io/kube-apiserver-amd64:v1.35.0 \
  | jq -r '.payload' | base64 -d | jq '.predicateType, .predicate'

# Or verify + return the attestation in one step (SLSA provenance predicate):
cosign verify-attestation registry.k8s.io/kube-apiserver-amd64:v1.35.0 \
  --type slsaprovenance \
  --certificate-identity krel-trust@k8s-releng-prod.iam.gserviceaccount.com \
  --certificate-oidc-issuer https://accounts.google.com | jq -r '.payload' | base64 -d | jq .
```

Kubernetes also documents verifying its release images + binaries end-to-end — see
"Verify Signed Kubernetes Artifacts" in the docs.

### 7.7 What our `unikube.yaml` would run for real (NOTATION, unstubbed)

```bash
IMG="ecr/tenant_Y_image:1.0.0"

# One-time: trust the CA (matches the Wiz validator's notary_ca_certificates) + register a key
notation cert add --type ca --store soe ./trust/ca.crt   # the ROOT — never the intermediate
# (key via a KMS/HSM plugin in prod; file key shown for the local test cert)
notation key add --plugin <kms-plugin> --id <key-id> soe-signer   # or a file-based key

# PUSH FIRST — the signature is stored in the registry next to the image it refers to.
docker push "$IMG"
REF="$(docker inspect --format '{{index .RepoDigests 0}}' "$IMG")"   # ecr/...@sha256:...

# Sign the pushed DIGEST (COSE signature, stored as an OCI artifact via referrers)
notation sign --signature-format cose --key soe-signer "$REF"

# Verify locally the way Wiz will — trust store AND trust policy; `notation verify`
# refuses to run without a policy. Verify against the COMMITTED trust/ca.crt, not the
# out/pki copy, or you are only proving the leaf matches the CA that just issued it.
notation cert add --type ca --store soe ./trust/ca.crt
notation policy import ./trustpolicy.json     # registryScopes, trustStores: ["ca:soe"],
                                              # trustedIdentities pinned to the signer CN
notation verify "$REF"
```

`trustedIdentities: ["*"]` would accept **any** leaf the CA ever issues; pin the signer's
subject instead. `signatureVerification.level: strict` enforces cert expiry — an image
signed by an expired leaf fails verification, which is exactly the revocation behaviour we
rely on (§ cert expiry). Full worked example: `unikube/README.md` step 4c.

`scripts/sign-image.sh` wraps the key-registration + sign half of this (cert/key from env or
a KMS plugin, expiry-checked); the workflow feeds it the digest from the push step.

No attestation digest to persist — admission is by signature, and the record of "why" is
the signed artifact in the registry plus the informational scan.

---

## 8. Good vs bad — quick checklist

Good:
- Gate on **base-layer digests** and **signed attestations**.
- **Pin base images by digest**; verify signer **identity**, not just "is signed."
- Store durable provenance (digests, commit) in git; keep the attestation in the registry.
- Keyless signing (OIDC) — no long-lived keys to leak.

Bad / traps:
- Trusting **label values** (`base.name`, `maintainer`, a `compliance=true` label) — all
  attacker-controlled.
- Pinning base images by **tag** (mutable — can be repointed after review).
- "It's signed" without checking **who** signed it (any valid Sigstore identity ≠ *your*
  workflow).
- Relying on a **CI log URL** as the record of why something was admitted — it expires.
- A too-broad compliant regex (`.*`) — always anchor exact FQINs (`^repo:tag$`).
