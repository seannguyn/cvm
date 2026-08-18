#!/usr/bin/env bash
# Can the KYVERNO ADMISSION CONTROLLER reach the registry and read signature referrers?
#
#   bash 00-prereqs/check-registry-access.sh <image@sha256:...>
#
# This is not the same question as "can I reach the registry" or "can the node pull the
# image". The admission controller pod does the fetch, with its own ServiceAccount, its own
# proxy environment and its own credential helpers. All three are separate ways for this to
# fail, and the failure surfaces at admission as an opaque verification error.
set -uo pipefail

IMAGE="${1:?usage: check-registry-access.sh <image@sha256:...>}"
NS="${KYVERNO_NAMESPACE:-kyverno}"
REG="${IMAGE%%/*}"
GRN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; OFF=$'\033[0m'

POD=$(kubectl -n "$NS" get pods -l app.kubernetes.io/component=admission-controller \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$POD" ] || { echo "no admission controller pod in $NS" >&2; exit 1; }
echo "probing from $NS/$POD"

# --- 1. credential helpers ----------------------------------------------------
ARGS=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.containers[0].args}')
if echo "$ARGS" | grep -q registryCredentialHelpers; then
  echo "  ${GRN}ok${OFF}    $(echo "$ARGS" | tr ',' '\n' | grep registryCredentialHelpers | tr -d '[]"')"
  case "$REG" in
    *.dkr.ecr.*|*amazonaws.com)
      echo "$ARGS" | grep -q amazon \
        && echo "  ${GRN}ok${OFF}    'amazon' helper enabled for ECR" \
        || echo "  ${RED}FAIL${OFF}  ECR registry but 'amazon' helper is NOT enabled -- every fetch 401s" ;;
  esac
else
  echo "  ${RED}FAIL${OFF}  --registryCredentialHelpers not set: NO helpers enabled, private registries will fail"
fi

# --- 2. IRSA ------------------------------------------------------------------
SA=$(kubectl -n "$NS" get pod "$POD" -o jsonpath='{.spec.serviceAccountName}')
ROLE=$(kubectl -n "$NS" get sa "$SA" -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}' 2>/dev/null)
case "$REG" in
  *.dkr.ecr.*|*amazonaws.com)
    if [ -n "$ROLE" ]; then
      echo "  ${GRN}ok${OFF}    SA $SA -> $ROLE"
      echo "        needs: ecr:GetAuthorizationToken, ecr:BatchGetImage, ecr:GetDownloadUrlForLayer"
    else
      echo "  ${RED}FAIL${OFF}  SA $SA has no eks.amazonaws.com/role-arn annotation -- no IRSA, no ECR access"
    fi ;;
  *) [ -n "$ROLE" ] && echo "  ok    SA $SA -> $ROLE" ;;
esac

# --- 3. proxy -----------------------------------------------------------------
ENVV=$(kubectl -n "$NS" get pod "$POD" -o json | jq -r '.spec.containers[0].env[]? | select(.name|test("(?i)proxy")) | "\(.name)=\(.value)"')
if [ -n "$ENVV" ]; then
  echo "$ENVV" | sed 's/^/  env   /'
  echo "$ENVV" | grep -qi "no_proxy.*$REG" && echo "  ${YEL}warn${OFF}  $REG appears in NO_PROXY -- direct egress must then work"
else
  echo "  note  no proxy env on the admission controller -- direct egress assumed"
fi

# --- 4. actual reachability ---------------------------------------------------
# The Kyverno image is distroless; wget/curl may not exist. Try, and fall back to a debug pod
# in the same namespace with the same ServiceAccount, which is the closest reproduction of the
# controller's network identity available without patching the deployment.
echo
echo "  probing $REG/v2/ ..."
if kubectl -n "$NS" exec "$POD" -c kyverno -- wget -qS --spider "https://$REG/v2/" 2>&1 | head -3 | sed 's/^/        /'; then :; else
  echo "        (no shell tooling in the Kyverno image -- falling back to a debug pod)"
  kubectl -n "$NS" run ivpol-netcheck --rm -i --restart=Never --quiet \
    --overrides="{\"spec\":{\"serviceAccountName\":\"$SA\"}}" \
    --image=curlimages/curl:latest -- \
    sh -c "curl -sS -o /dev/null -w 'registry /v2/  http=%{http_code}  connect=%{time_connect}s  total=%{time_total}s\n' https://$REG/v2/ || echo UNREACHABLE" \
    2>/dev/null | sed 's/^/        /'
  echo "        http=401 is GOOD -- the registry is reachable and asking for auth."
  echo "        UNREACHABLE or a hang means the proxy allowlist does not cover $REG from this"
  echo "        namespace, and every cold-cache verification will sit there until the webhook"
  echo "        timeout fires."
fi

# --- 5. referrers API ---------------------------------------------------------
echo
echo "  referrers API (how Notary signatures are found):"
if command -v oras >/dev/null; then
  oras discover -o json "$IMAGE" 2>&1 | jq -r '
    if .manifests then "        \(.manifests|length) referrer(s): " + ([.manifests[].artifactType]|join(", "))
    else "        no referrers -- the image is unsigned, or the registry does not implement /v2/<name>/referrers/<digest>"
    end' 2>/dev/null || echo "        oras discover failed: $IMAGE"
else
  echo "        (oras not installed locally -- install it, this is the fastest way to see"
  echo "         whether a signature exists at all before blaming the policy)"
fi

echo
echo "Remember: if evaluation.background.enabled is true on any policy, the REPORTS controller"
echo "needs the same registry access. It is a separate pod, a separate ServiceAccount and"
echo "possibly a separate proxy config -- re-run this with KYVERNO_NAMESPACE set and the"
echo "component label changed, or you will find out during P17."
