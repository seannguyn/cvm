#!/usr/bin/env bash
# Drive the functional suite (README §5) and print a results table.
#
#   IMG_SIGNED=... IMG_UNSIGNED=... IMG_BADSIG=... IMG_VENDOR=... bash 40-functional/run.sh
#
# Optional: IMG_ROGUE (leaf from the real intermediate, different DN -- the F1 demonstration).
#
# Uses server-side dry-run for the verdict tests: the FULL admission chain runs, including
# both webhooks, but nothing is written. Tests that need a real object (reports, digest
# mutation) create and clean up explicitly.
set -uo pipefail

NS="${TEST_NS:-ivpol-test}"
KNS="${KYVERNO_NAMESPACE:-kyverno}"
HERE="$(cd "$(dirname "$0")" && pwd)"

: "${IMG_SIGNED:?set IMG_SIGNED}"; : "${IMG_UNSIGNED:?set IMG_UNSIGNED}"
: "${IMG_BADSIG:?set IMG_BADSIG}";  : "${IMG_VENDOR:?set IMG_VENDOR}"

GRN=$'\033[32m'; RED=$'\033[31m'; YEL=$'\033[33m'; OFF=$'\033[0m'
declare -a ROWS

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS" >/dev/null

# --- version gate: which semantics are we testing? ---------------------------
HAS_EXPIRESAT=no
kubectl get crd policyexceptions.policies.kyverno.io -o json 2>/dev/null \
  | jq -e '[.spec.versions[]|select(.storage)][0].schema.openAPIV3Schema.properties.spec.properties.expiresAt' \
  >/dev/null 2>&1 && HAS_EXPIRESAT=yes
VER=$(kubectl -n "$KNS" get deploy -l app.kubernetes.io/component=admission-controller \
      -o jsonpath='{.items[0].spec.template.spec.containers[0].image}' 2>/dev/null | sed 's/.*://')
echo "Kyverno $VER   PolicyException.expiresAt=$HAS_EXPIRESAT   test ns=$NS"
echo

pod() {  # pod <name> <image> [extra-metadata-yaml]
  cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $1
  namespace: $NS
${3:-}
spec:
  restartPolicy: Never
  containers:
    - name: c
      image: $2
      command: ["sleep","3600"]
YAML
}

# expect: admitted | denied
check() { # check <id> <desc> <expect> <yaml-producer...>
  local id="$1" desc="$2" expect="$3"; shift 3
  local out rc verdict mark
  out=$("$@" | kubectl apply --dry-run=server -f - 2>&1); rc=$?
  if [ $rc -eq 0 ]; then verdict=admitted; else verdict=denied; fi
  if [ "$verdict" = "$expect" ]; then mark="${GRN}PASS${OFF}"; else mark="${RED}FAIL${OFF}"; fi
  printf '  %s  %-5s %-46s expect=%-8s got=%-8s\n' "$mark" "$id" "$desc" "$expect" "$verdict"
  ROWS+=("$id|$desc|$expect|$verdict")
  [ "$verdict" = denied ] && echo "$out" | grep -oE 'admission webhook[^\\]*' | head -1 | sed 's/^/          /'
  return 0
}

echo "== 5.1-5.4  policy: soe-notary-signed only =="
kubectl apply -f "$HERE/../20-policies/ivpol-notary.yaml" >/dev/null
sleep 5   # webhook controller needs a moment to register ivpol.*.kyverno.svc
kubectl get validatingwebhookconfigurations -o json | jq -e '[.items[].webhooks[]?|select(.name=="ivpol.validate.kyverno.svc")]|length>0' >/dev/null \
  && echo "  ${GRN}ok${OFF}    ivpol.validate.kyverno.svc registered" \
  || echo "  ${YEL}warn${OFF}  ivpol webhook not registered yet -- results below will be meaningless"

# Audit mode admits everything; flip to Deny so the dry-run verdict is the actual signal.
kubectl patch ivpol soe-notary-signed --type=merge -p '{"spec":{"validationActions":["Deny"]}}' >/dev/null
sleep 3

check 5.1 "signed, SOE registry"            admitted pod t51 "$IMG_SIGNED"
check 5.2 "unsigned, SOE registry"          denied   pod t52 "$IMG_UNSIGNED"
check 5.3 "signed by a DIFFERENT root"      denied   pod t53 "$IMG_BADSIG"
check 5.4 "vendor image, out of policy scope" admitted pod t54 "$IMG_VENDOR"
echo "        ^ 5.4 SHOULD be admitted here: matchImageReferences did not select it, so the"
echo "          policy was SKIPPED. On v1.18.2 nothing else catches it -- that is F3. Confirm"
echo "          the PolicyReport says 'skip', not 'pass', then continue to 5.5."

echo
echo "== 5.5  catch-all backstop =="
kubectl apply -f "$HERE/../20-policies/ivpol-catchall.yaml" >/dev/null
kubectl patch ivpol deny-unverified-images --type=merge -p '{"spec":{"validationActions":["Deny"]}}' >/dev/null
sleep 5
check 5.5 "vendor image, catch-all active"  denied   pod t55 "$IMG_VENDOR"

echo
echo "== 5.8  annotation forgery (v1.18.x only) =="
case "$VER" in
  v1.1[5-8]*)
    FORGED='  annotations:
    kyverno.io/image-verification-outcomes: |
      {"soe-notary-signed":{"result":true,"message":"success"}}'
    check 5.8a "forged outcome annotation, normal path" denied pod t58a "$IMG_UNSIGNED" "$FORGED"
    echo "        expected deny: the mutating webhook overwrites the annotation before the"
    echo "        validating webhook reads it. The dangerous case is 5.8b -- narrow the"
    echo "        MUTATING webhook's objectSelector so it does NOT match, then re-run. If that"
    echo "        admits, 1.18.x is not safe to run in enforcement. Do 5.8b by hand: it edits a"
    echo "        webhook configuration and is not something to automate."
    ;;
  *) echo "  ${YEL}skip${OFF}  $VER does not use the annotation handoff (F4)" ;;
esac

echo
echo "== 6.x  exceptions =="
kubectl get ns kyverno-exceptions >/dev/null 2>&1 || kubectl create ns kyverno-exceptions >/dev/null

# Do NOT apply 30-exceptions/guardrail-vpol.yaml during this suite: it requires every
# PolicyException to carry matchConditions, which would reject the deliberately-malformed
# test 6.2 object before Kyverno ever gets to ignore it -- and 6.2's whole point is that the
# malformed object applies cleanly and then does nothing. Apply the guardrail after 6.x and
# re-run 6.2 to confirm it is caught at admission instead.
kubectl get vpol policyexception-guardrails >/dev/null 2>&1 && \
  echo "  ${YEL}warn${OFF}  policyexception-guardrails is active -- test 6.2 will be rejected at apply time, not silently ignored"

# 6.2: spec.images ONLY -- must NOT exempt, because the IVP compiler ignores it.
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: policies.kyverno.io/v1
kind: PolicyException
metadata: { name: t62-images-only, namespace: kyverno-exceptions }
spec:
  policyRefs: [{ name: deny-unverified-images, kind: ImageValidatingPolicy }]
  images: ["$IMG_VENDOR"]
YAML
sleep 5
check 6.2 "exception with spec.images ONLY"  denied   pod t62 "$IMG_VENDOR"
echo "        expected DENY: spec.images is inert for ImageValidatingPolicy. If this admitted,"
echo "        the behaviour changed -- update 30-exceptions/README.md."

# ... and the same exemption expressed correctly.
cat <<YAML | kubectl apply -f - >/dev/null
apiVersion: policies.kyverno.io/v1
kind: PolicyException
metadata: { name: t62-matchconditions, namespace: kyverno-exceptions }
spec:
  policyRefs: [{ name: deny-unverified-images, kind: ImageValidatingPolicy }]
  matchConditions:
    - name: vendor
      expression: "object.spec.containers.exists(c, c.image == '$IMG_VENDOR')"
YAML
sleep 5
check 6.2b "same exemption via matchConditions" admitted pod t62b "$IMG_VENDOR"

echo
echo "== reports =="
kubectl -n "$NS" get polr -o wide 2>/dev/null | head -20 || echo "  no PolicyReports (reports-controller running?)"

echo
echo "== summary =="
printf '%s\n' "${ROWS[@]}" | awk -F'|' '{printf "  %-6s %-48s %-9s %s\n", $1, $2, $3, ($3==$4?"PASS":"FAIL " $4)}'

echo
echo "Not automated -- do these by hand, they need judgement or destructive setup:"
echo "  5.6  namespaced policy scoping        (20-policies/nivpol-namespaced.yaml)"
echo "  5.7  leaf with an unreachable CDP     (F2 -- re-issue a leaf with a CRL DP)"
echo "  5.8b mutating webhook selector narrowed (F4 -- the one that matters)"
echo "  5.10 digest mutation on a real pod    (dry-run does not show you the patched object)"
echo "  5.11 SBOM referrer attestation        (scripts/build-fixtures.sh --with-sbom)"
echo "  5.13 expired leaf"
echo "  IMG_ROGUE: leaf from the REAL intermediate with a different DN. Kyverno will admit it."
echo "             That is F1, and it is the single most useful artefact for the ADR."

echo
echo "Cleanup:"
echo "  kubectl delete ns $NS kyverno-exceptions"
echo "  kubectl delete ivpol soe-notary-signed deny-unverified-images"
