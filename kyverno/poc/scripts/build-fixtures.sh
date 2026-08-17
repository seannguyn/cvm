#!/usr/bin/env bash
# Build and push the five test images (README §4). Prints the exports the other scripts need.
#
#   REGISTRY=container-soe.registry.domain/test bash scripts/build-fixtures.sh [--with-sbom]
#
# Reuses the REAL signing chain via the existing wiz/ tooling, because the point is to test
# the signatures CI actually produces -- not a lookalike.
#
# Required for the signed fixture (same contract as wiz/.../sign-image.sh):
#   NOTATION_SIGNING_CERT   full chain PEM, leaf first (out/pki/signing-chain.crt)
#   NOTATION_SIGNING_KEY    private key matching the leaf
set -euo pipefail

REGISTRY="${REGISTRY:?set REGISTRY, e.g. container-soe.registry.domain/test}"
WITH_SBOM=""; [ "${1:-}" = "--with-sbom" ] && WITH_SBOM=1
HERE="$(cd "$(dirname "$0")" && pwd)"
SIGN="$HERE/../../wiz/container-vulnerability-exemption/unikube/scripts/sign-image.sh"
GENCERTS="$HERE/../../wiz/container-vulnerability-exemption/unikube/scripts/gen_signing_certs.sh"

for t in docker notation oras jq openssl; do
  command -v $t >/dev/null || { echo "missing: $t" >&2; exit 1; }
done
[ -f "$SIGN" ] || { echo "not found: $SIGN -- run from the kyverno/ directory of the repo" >&2; exit 1; }

TAG="ivpol-$(date +%Y%m%d-%H%M%S)"
BUILD="$(mktemp -d)"; trap 'rm -rf "$BUILD"' EXIT
cat > "$BUILD/Dockerfile" <<'EOF'
FROM scratch
COPY payload /payload
EOF

mk() { # mk <suffix> <payload-content> -> prints image@digest
  local sfx="$1"
  printf '%s' "$2" > "$BUILD/payload"
  local ref="$REGISTRY:${TAG}-${sfx}"
  docker build -q -t "$ref" "$BUILD" >/dev/null
  docker push "$ref" >/dev/null
  local dig
  dig=$(docker inspect --format='{{index .RepoDigests 0}}' "$ref" 2>/dev/null | sed 's/.*@//')
  [ -n "$dig" ] || dig=$(docker manifest inspect "$ref" 2>/dev/null | jq -r '.config.digest')
  echo "${REGISTRY}@${dig}"
}

echo "building fixtures under $REGISTRY, tag prefix $TAG" >&2

# --- IMG_SIGNED --------------------------------------------------------------
: "${NOTATION_SIGNING_CERT:?need NOTATION_SIGNING_CERT (full chain, leaf first)}"
: "${NOTATION_SIGNING_KEY:?need NOTATION_SIGNING_KEY}"
IMG_SIGNED=$(mk signed "compliant")
bash "$SIGN" "$IMG_SIGNED" >&2
echo "  IMG_SIGNED   $IMG_SIGNED" >&2

# --- IMG_UNSIGNED ------------------------------------------------------------
# Distinct content, so it is a different digest -- otherwise it would inherit the signature,
# which is the kind of subtle fixture bug that makes a whole suite pass for the wrong reason.
IMG_UNSIGNED=$(mk unsigned "not-compliant")
echo "  IMG_UNSIGNED $IMG_UNSIGNED" >&2

# --- IMG_BADSIG: signed by a throwaway root ----------------------------------
# This is the test that proves the trust store does work rather than just checking that a
# signature exists. Throwaway PKI in a scratch dir -- gen_signing_certs.sh writes keys to disk
# and is test material only (ADR-0003).
SCRATCH="$(mktemp -d)"
( cd "$SCRATCH" && bash "$GENCERTS" >/dev/null 2>&1 ) || {
  echo "  gen_signing_certs.sh failed in $SCRATCH -- build IMG_BADSIG by hand" >&2; }
IMG_BADSIG=$(mk badsig "wrong-root")
if [ -f "$SCRATCH/out/pki/signing-chain.crt" ]; then
  NOTATION_SIGNING_CERT="$(cat "$SCRATCH/out/pki/signing-chain.crt")" \
  NOTATION_SIGNING_KEY="$(cat "$SCRATCH/out/pki/signing.key")" \
  NOTATION_KEY_NAME=throwaway \
  bash "$SIGN" "$IMG_BADSIG" >&2
fi
echo "  IMG_BADSIG   $IMG_BADSIG   (root: $SCRATCH/out/pki/root.crt)" >&2
rm -rf "$SCRATCH"

# --- IMG_VENDOR --------------------------------------------------------------
IMG_VENDOR="${IMG_VENDOR:-docker.io/library/nginx:1.27.3}"
echo "  IMG_VENDOR   $IMG_VENDOR" >&2

# --- SBOM referrer (test 5.11) ------------------------------------------------
if [ -n "$WITH_SBOM" ]; then
  # Notary can only verify OCI 1.1 REFERRER attestations -- intoto is Cosign-only. So the SBOM
  # is attached as a referrer and then signed as its own artifact: two signing operations, not
  # one. This is the part people get wrong.
  cat > "$BUILD/sbom.json" <<'EOF'
{"spdxVersion":"SPDX-2.3","name":"ivpol-test","packages":[]}
EOF
  oras attach --artifact-type application/spdx+json "$IMG_SIGNED" \
    "$BUILD/sbom.json:application/spdx+json" >&2
  SBOM_DIGEST=$(oras discover -o json --artifact-type application/spdx+json "$IMG_SIGNED" \
    | jq -r '.manifests[0].digest')
  bash "$SIGN" "${IMG_SIGNED%@*}@${SBOM_DIGEST}" >&2
  echo "  SBOM attached and signed: $SBOM_DIGEST" >&2
fi

# --- IMG_ROGUE: the F1 demonstration -----------------------------------------
cat >&2 <<'EOF'

IMG_ROGUE is deliberately NOT built here.

It is a leaf issued from the REAL intermediate with a different DN
(CN=not-the-soe-signer), signed and pushed. Kyverno will ADMIT it, because the Notation
trust policy is constructed in Go with TrustedIdentities: ["*"] and there is no field to
change that. That is finding F1, and it contradicts ADR-0003's claim that Kyverno
"supports [identity pinning] today".

Building it means touching the real intermediate key, which ADR-0003 treats as crown-jewel
material. Either get it issued properly through the PKI process, or build the same
demonstration with a throwaway three-tier PKI and trust THAT root in a scratch policy -- the
finding is identical and the blast radius is zero. Prefer the second.
EOF

cat <<EOF

export IMG_SIGNED='$IMG_SIGNED'
export IMG_UNSIGNED='$IMG_UNSIGNED'
export IMG_BADSIG='$IMG_BADSIG'
export IMG_VENDOR='$IMG_VENDOR'
EOF
