# Image labels, digests, cosign & attestation — a 101

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

## 6. How this project uses it

The unikube workflow (`.github/workflows/unikube.yaml`) does, per target cluster:

1. **Static** base-image check — every `FROM` must be `container-soe.registry.domain/*`.
2. **Build.**
3. **Authoritative** check — `docker inspect` the built image's base-layer **digests** +
   the final base image's `.Created` (freshness ≤ 30 days). **Digests, not labels.**
4. **Sign + attest** — cosign (keyless) signs, then attaches SLSA provenance + the custom
   compliance predicate. We capture the **attestation digest**.
5. **Wiz scan** — AUDIT, informational only.
6. **No `wiz tag`** — attestation is optional; admission is name/regex based.
7. **Auto-merge PR** — writes the exact FQIN + provenance into `<env>/<cluster>.compliant.yaml`.

**What we persist, and why:** the CI run log link expires, so it's a poor system of
record. Instead each `compliant_images` entry stores durable evidence in git:
`base_image` + `base_image_digest` (what it was built on), `attestation_digest` (pointer to
the signed statement, which lives in the registry forever), and `source_repo` +
`source_commit` (who/where). Anyone can later re-verify the attestation by digest.

> Mock note: there is no real registry/OIDC in this repo, so the cosign calls in
> `unikube.yaml` are **stubbed** (echo + a placeholder digest). The step order and the
> stored fields are real, so dropping in real cosign is mechanical.

---

## 7. Hands-on — real commands you can run

Tools used below: `docker`, [`crane`](https://github.com/google/go-containerregistry) (works
without a daemon), `skopeo`, `cosign`, `jq`. Install crane/cosign from their releases; `jq`
from your package manager.

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

### 7.7 What our `unikube.yaml` would run for real (unstubbed)

```bash
IMG="ecr/tenant_Y_image:1.0.0"
DIGEST=$(crane digest "$IMG")

# sign + attest (keyless via the Actions OIDC identity)
cosign sign --yes "$IMG@$DIGEST"
cosign attest --yes --type slsaprovenance --predicate provenance.json "$IMG@$DIGEST"
cosign attest --yes --type custom          --predicate compliance.json "$IMG@$DIGEST"

# the durable pointer we store in <cluster>.compliant.yaml:
ATT_DIGEST=$(crane digest "$(cosign triangulate "$IMG@$DIGEST" --type attestation 2>/dev/null || echo "$IMG:sha256-...att")")
echo "attestation_digest=$ATT_DIGEST"
```

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
