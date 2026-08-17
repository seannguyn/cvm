#!/usr/bin/env bash
# Verify a signed image locally under EXACTLY the trust policy Kyverno hardcodes, so that a
# local pass is a real predictor of an admission pass.
#
#   bash 10-trust/verify-locally.sh <image@sha256:...> <ca.crt>
#
# WHY THIS IS NOT `notation verify` WITH YOUR NORMAL TRUST POLICY:
# Kyverno does not read a trustpolicy.json. It constructs one in Go and gives you no way to
# change it (pkg/image/verifiers/ivpol/notary/helpers.go):
#
#     RegistryScopes:    ["*"]
#     VerificationLevel: strict
#     TrustStores:       ["ca:kyverno"]  (+ "tsa:kyverno" when tsaCerts is set)
#     TrustedIdentities: ["*"]
#
# Two consequences this script exists to surface:
#
#  1. TrustedIdentities ["*"] -- ANY leaf chaining to the anchor verifies, regardless of DN.
#     If your local trust policy pins trustedIdentities to the SOE signer's DN, your local
#     test is STRICTER than Kyverno and will not catch the rogue-signer case. That is finding
#     F1 and it contradicts ADR-0003's claim that Kyverno "supports [identity pinning] today".
#
#  2. level strict -- revocation is ENFORCED. Certs with no AIA/CDP score NonRevokable, which
#     counts as OK, so today's leaves pass without egress. Add a CRL distribution point to the
#     PKI and admission acquires a hard egress dependency. That is F2, and test 5.7.
set -euo pipefail

IMAGE="${1:?usage: verify-locally.sh <image@sha256:...> <ca.crt>}"
CA="${2:?usage: verify-locally.sh <image@sha256:...> <ca.crt>}"

command -v notation >/dev/null || { echo "notation CLI not found" >&2; exit 1; }
[ -f "$CA" ] || { echo "not found: $CA" >&2; exit 1; }

case "$IMAGE" in
  *@sha256:*) ;;
  *) echo "WARNING: '$IMAGE' is a tag. Kyverno verifies the resolved DIGEST; a tag that moved" >&2
     echo "         between here and admission makes this test meaningless. Prefer a digest." >&2 ;;
esac

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
export XDG_CONFIG_HOME="$WORK"   # Linux only; on macOS notation ignores this (see sign-image.sh)
if [ "$(uname -s)" = "Darwin" ]; then
  echo "NOTE: macOS -- notation reads ~/Library/Application Support/notation and ignores" >&2
  echo "      XDG_CONFIG_HOME, so this script cannot isolate its config. Run it in Linux/CI" >&2
  echo "      or accept that it touches your real trust store." >&2
fi

DIR="${XDG_CONFIG_HOME}/notation"
mkdir -p "$DIR/truststore/x509/ca/kyverno"
cp "$CA" "$DIR/truststore/x509/ca/kyverno/ca.crt"

cat > "$DIR/trustpolicy.json" <<'JSON'
{
  "version": "1.0",
  "trustPolicies": [
    {
      "name": "kyverno",
      "registryScopes": [ "*" ],
      "signatureVerification": { "level": "strict" },
      "trustStores": [ "ca:kyverno" ],
      "trustedIdentities": [ "*" ]
    }
  ]
}
JSON

echo "trust policy: level=strict, trustedIdentities=[*]  (identical to Kyverno's hardcoded policy)"
echo "anchor:       $(openssl x509 -in "$CA" -noout -subject | sed 's/^subject= *//')"
echo

set +e
OUT=$(notation verify -v "$IMAGE" 2>&1); RC=$?
set -e
echo "$OUT"
echo

if [ $RC -eq 0 ]; then
  echo "PASS -- this image will verify at admission, given the same anchor in the policy."
  echo
  echo "Reminder: a PASS here says the chain terminates at the anchor. It says NOTHING about"
  echo "WHO signed it -- trustedIdentities is [*]. To see what that means in practice, build"
  echo "the IMG_ROGUE fixture (a leaf from the same intermediate with a different DN) and run"
  echo "this again: it will also pass. That is the artefact worth putting in the ADR."
else
  echo "FAIL -- and it will fail at admission too. Common causes, in order:"
  echo "  * signature envelope carries a bare leaf, not the full chain (sign-image.sh refuses"
  echo "    this, but a signature made by hand or by an older pipeline may have it)"
  echo "  * wrong anchor: intermediate pinned instead of root"
  echo "  * leaf expired -- signatures are deliberately not trust-timestamped (ADR-0001), so"
  echo "    the leaf's validity window is checked against NOW"
  echo "  * registry does not expose the referrers API, so no signature was found at all"
  echo "  * revocation: a CDP/AIA URL on the chain that cannot be reached (F2)"
fi
exit $RC
