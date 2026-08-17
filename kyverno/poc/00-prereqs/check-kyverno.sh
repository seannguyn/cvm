#!/usr/bin/env bash
# Establish whether this cluster can run the ImageValidatingPolicy tests, and which VERSION
# semantics apply. Read-only -- creates nothing, changes nothing.
#
#   bash 00-prereqs/check-kyverno.sh [-n kyverno]
#
# Exit 0 = ready. Exit 1 = a hard blocker. Warnings do not fail the run, because several of
# them ("the ivpol webhook does not exist yet") are expected before the first policy lands.
set -uo pipefail

NS="${KYVERNO_NAMESPACE:-kyverno}"
while getopts "n:" o; do case $o in n) NS="$OPTARG" ;; esac; done

RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; DIM=$'\033[2m'; OFF=$'\033[0m'
FAIL=0
ok()   { echo "  ${GRN}ok${OFF}    $*"; }
warn() { echo "  ${YEL}warn${OFF}  $*"; }
bad()  { echo "  ${RED}FAIL${OFF}  $*"; FAIL=1; }
note() { echo "        ${DIM}$*${OFF}"; }
hdr()  { echo; echo "== $* =="; }

command -v kubectl >/dev/null || { echo "kubectl not found"; exit 1; }
command -v jq >/dev/null      || { echo "jq not found"; exit 1; }

hdr "Cluster"
kubectl version -o json 2>/dev/null | jq -r '"  server: \(.serverVersion.gitVersion)"' || bad "cannot reach cluster"

# ---------------------------------------------------------------- controllers
hdr "Kyverno controllers (namespace: $NS)"
DEPLOYS=$(kubectl -n "$NS" get deploy -o json 2>/dev/null) || { bad "namespace $NS not found or not readable"; echo; exit 1; }

for d in admission-controller background-controller cleanup-controller reports-controller; do
  row=$(echo "$DEPLOYS" | jq -r --arg d "$d" '.items[] | select(.metadata.name|test($d)) | "\(.metadata.name) \(.status.readyReplicas // 0)/\(.spec.replicas)"' | head -1)
  if [ -z "$row" ]; then
    case $d in
      admission-controller) bad "$d not installed -- IVP admission cannot work" ;;
      reports-controller)   warn "$d not installed -- no PolicyReports, and background scan (P17) cannot run"
                            note "the functional suite reads PolicyReport results; without it you are reading webhook responses only" ;;
      cleanup-controller)   warn "$d not installed -- the v1.18 composed exemption expiry (test 6.5) cannot run" ;;
      background-controller) warn "$d not installed -- background evaluation unavailable" ;;
    esac
  else
    set -- $row
    if [ "${2%%/*}" = "0" ]; then bad "$1 present but 0 replicas ready ($2)"; else ok "$1 $2"; fi
  fi
done

# ---------------------------------------------------------------- version
hdr "Version"
IMG=$(echo "$DEPLOYS" | jq -r '.items[] | select(.metadata.name|test("admission-controller")) | .spec.template.spec.containers[0].image' | head -1)
VER=$(echo "$IMG" | sed 's/.*://')
echo "  image: $IMG"
MAJMIN=$(echo "$VER" | sed -E 's/^v?([0-9]+)\.([0-9]+).*/\1.\2/')
case "$MAJMIN" in
  1.1[0-4]) bad "Kyverno $VER predates ImageValidatingPolicy (needs >= 1.15, stable at 1.18)" ;;
  1.1[5-7]) warn "Kyverno $VER -- IVP present but pre-stable; expect API churn vs the docs" ;;
  1.18)     ok "Kyverno $VER -- IVP stable"
            note "v1.18 semantics apply: validationConfigurations.required is INERT (F3);"
            note "verification runs in the MUTATING webhook and is handed to the validating"
            note "webhook via the kyverno.io/image-verification-outcomes annotation (F4);"
            note "PolicyException has no expiresAt (F5). Run tests 5.5, 5.8, 6.3." ;;
  1.19|1.2*) ok "Kyverno $VER -- v1.19+ semantics"
            note "required catch-all enforced; verification in the validating webhook only;"
            note "PolicyException.expiresAt available." ;;
  *)        warn "could not classify version '$VER'" ;;
esac

# ---------------------------------------------------------------- CRDs
hdr "CRDs"
for crd in imagevalidatingpolicies.policies.kyverno.io \
           namespacedimagevalidatingpolicies.policies.kyverno.io \
           policyexceptions.policies.kyverno.io; do
  j=$(kubectl get crd "$crd" -o json 2>/dev/null)
  if [ -z "$j" ]; then
    bad "$crd missing"
    note "Helm gates these: crds.groups.policies.<name>=true. See 00-prereqs/values-ivpol.yaml"
  else
    served=$(echo "$j" | jq -r '[.spec.versions[]|select(.served)|.name]|join(",")')
    storage=$(echo "$j" | jq -r '.spec.versions[]|select(.storage)|.name')
    ok "$crd  served=[$served] storage=$storage"
  fi
done

# Does PolicyException have expiresAt on this cluster? Decides 6.3 vs 6.5.
PX=$(kubectl get crd policyexceptions.policies.kyverno.io -o json 2>/dev/null)
if [ -n "$PX" ]; then
  if echo "$PX" | jq -e '[.spec.versions[]|select(.storage)][0].schema.openAPIV3Schema.properties.spec.properties.expiresAt' >/dev/null 2>&1; then
    ok "PolicyException.spec.expiresAt present -- native exemption expiry (test 6.4)"
  else
    warn "PolicyException.spec.expiresAt ABSENT -- use the composed ClusterCleanupPolicy (test 6.5)"
    note "and note that applying polex-expiresAt-1.19.yaml here would SILENTLY DROP the field"
  fi
fi

# ---------------------------------------------------------------- flags
hdr "Admission controller flags"
ARGS=$(echo "$DEPLOYS" | jq -r '.items[] | select(.metadata.name|test("admission-controller")) | .spec.template.spec.containers[0].args[]?' 2>/dev/null)
getflag() { echo "$ARGS" | grep -oE -- "--$1(=[^ ]*)?" | head -1; }

pe=$(getflag enablePolicyException)
case "$pe" in
  *=true) ok "--enablePolicyException=true" ;;
  "")     bad "--enablePolicyException not set (defaults to FALSE) -- every PolicyException will be silently ignored" ;;
  *)      bad "$pe -- PolicyExceptions will be silently ignored" ;;
esac

en=$(getflag exceptionNamespace)
case "$en" in
  *='*') warn "--exceptionNamespace='*' -- exceptions honoured in EVERY namespace"
         note "anyone who can create a PolicyException anywhere can exempt the whole cluster;"
         note "matchConditions is unrestricted CEL. Pin to one namespace. See 30-exceptions/README.md" ;;
  "")    warn "--exceptionNamespace not set -- exceptions are not honoured anywhere" ;;
  *)     ok "$en" ;;
esac

for f in imageVerifyCacheEnabled imageVerifyCacheTTLDuration imageVerifyCacheMaxSize; do
  v=$(getflag "$f")
  if [ -n "$v" ]; then ok "$v"; else
    case $f in
      imageVerifyCacheEnabled)     note "--imageVerifyCacheEnabled unset -> default true" ;;
      imageVerifyCacheTTLDuration) note "--imageVerifyCacheTTLDuration unset -> default 60m" ;;
      imageVerifyCacheMaxSize)     warn "--imageVerifyCacheMaxSize unset -> default 1000 entries"
                                   note "1000 distinct (policy,image) pairs is small for a 200-cluster fleet; sweep it in P4" ;;
    esac
  fi
done
note "these three are NOT Helm chart values -- set them via admissionController.container.extraArgs"

rh=$(getflag registryCredentialHelpers)
if [ -n "$rh" ]; then
  ok "$rh"
  echo "$rh" | grep -q amazon || warn "credential helpers do not include 'amazon' -- ECR pulls will fail with 401"
else
  warn "--registryCredentialHelpers not set -- NO credential helpers are enabled and every private-registry fetch will fail"
fi

ir=$(getflag allowInsecureRegistry)
[ -n "$ir" ] && warn "$ir set -- must be false against a real registry"

# ---------------------------------------------------------------- webhooks
hdr "Webhooks"
for w in ivpol.validate.kyverno.svc ivpol.mutate.kyverno.svc; do
  found=$(kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o json 2>/dev/null \
    | jq -r --arg w "$w" '.items[] | .webhooks[]? | select(.name==$w) |
        "\(.name) failurePolicy=\(.failurePolicy) timeout=\(.timeoutSeconds)s nsSel=\(.namespaceSelector//{}|tostring) objSel=\(.objectSelector//{}|tostring)"')
  if [ -z "$found" ]; then
    warn "$w not present"
    note "expected before the first IVP is applied -- Kyverno creates these on demand. Re-run after 20-policies/"
  else
    echo "$found" | while read -r line; do ok "$line"; done
  fi
done

# The F4 hole: mutate and validate selectors must agree, or verification can be skipped while
# enforcement still runs (or vice versa).
MSEL=$(kubectl get mutatingwebhookconfigurations -o json 2>/dev/null | jq -c '[.items[].webhooks[]?|select(.name=="ivpol.mutate.kyverno.svc")|{ns:.namespaceSelector,obj:.objectSelector,fp:.failurePolicy}]')
VSEL=$(kubectl get validatingwebhookconfigurations -o json 2>/dev/null | jq -c '[.items[].webhooks[]?|select(.name=="ivpol.validate.kyverno.svc")|{ns:.namespaceSelector,obj:.objectSelector,fp:.failurePolicy}]')
if [ "$MSEL" != "[]" ] && [ "$VSEL" != "[]" ]; then
  if [ "$MSEL" = "$VSEL" ]; then
    ok "ivpol mutate/validate selectors and failurePolicy match"
  else
    bad "ivpol mutate and validate webhooks DISAGREE on selectors or failurePolicy"
    note "mutate:   $MSEL"
    note "validate: $VSEL"
    note "on v1.18.x this is the annotation-forgery hole (F4) -- run test 5.8 before going further"
  fi
fi

hdr "Other admission webhooks on pods (combined latency, ADR-0002 dual-webhook risk)"
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations -o json 2>/dev/null \
 | jq -r '.items[] | .metadata.name as $c | .webhooks[]? |
    select([.rules[]?.resources[]?]|index("pods")) |
    "  \($c)  \(.name)  failurePolicy=\(.failurePolicy) timeout=\(.timeoutSeconds//30)s"' \
 | sort -u
note "count the fail-closed ones. Two independent fail-closed webhooks on pods is two"
note "independent ways to stop all deployments -- measure them together in P12, not separately"

# ---------------------------------------------------------------- config
hdr "kyverno ConfigMap"
CM=$(kubectl -n "$NS" get cm kyverno -o json 2>/dev/null)
if [ -n "$CM" ]; then
  rf=$(echo "$CM" | jq -r '.data.resourceFilters // ""')
  if [ -n "$rf" ]; then
    echo "  resourceFilters set (${#rf} chars)"
    note "if your test namespace matches one of these, NOTHING will fire and you will not be told why"
    echo "$rf" | tr '][' '\n' | grep -Ei 'ivpol|test' | sed 's/^/        candidate match: /' || true
  fi
  echo "$CM" | jq -r '.data | to_entries[] | select(.key|test("excludeGroups|excludeUsernames|excludeRoles")) | "  \(.key)=\(.value)"'
  note "requests from excluded users/groups bypass Kyverno entirely -- check your CI identity is not in there"
else
  warn "kyverno ConfigMap not found in $NS"
fi

hdr "Result"
if [ $FAIL -eq 0 ]; then
  echo "  ${GRN}ready${OFF} -- proceed to 10-trust/"
else
  echo "  ${RED}blocked${OFF} -- resolve the FAIL lines above"
fi
exit $FAIL
