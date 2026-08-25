#!/usr/bin/env bash
# The §11 admission matrix, against the live cluster.
# Run from container-vulnerability-exemption/poc/
#
#   source env.sh && bash run-advanced-tests.sh 2>&1 | tee advanced-tests.txt
#
# verify-advanced.py proves the CEL SELECTS the right pods, offline and exhaustively. This proves
# the other half, which no offline evaluator can: that Kyverno compiles the expressions, reaches
# the registry, verifies real Notation signatures against the real CA, and that autogen carries a
# PolicyException's matchConditions onto pod controllers. Cases 15 and 16 exist only for that last
# question -- it is unverified upstream, and being wrong denies every Deployment on day one.
#
# Creates and deletes pods in $DEMO_NS. Leaves nothing behind.
set -uo pipefail

: "${DEMO_NS:?source env.sh first}"; : "${IMG_10:?}"; : "${IMG_20:?}"; : "${IMG_30:?}"
: "${VENDOR_A:?}"; : "${VENDOR_B:?}"; : "${VENDOR_X:?}"; : "${IMG_T2:?source §11.5 first}"

PASS=0; FAIL=0; FAILED=()

cleanup() {
  kubectl -n "$DEMO_NS" delete pod -l demo=advanced --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n "$DEMO_NS" delete deploy,cronjob -l demo=advanced --ignore-not-found >/dev/null 2>&1
}
trap cleanup EXIT
cleanup; sleep 2

# case <n> <expect: ADMIT|BLOCK> <label> <image...>
case_pod() {
  local n=$1 want=$2 label=$3; shift 3
  local name="adv-${n}" ctrs="" i=0 out rc got
  for img in "$@"; do
    i=$((i+1))
    ctrs+="    - {name: c${i}, image: ${img}, command: [\"sh\",\"-c\",\"sleep 604800\"]}
"
  done
  out=$(kubectl apply -f - 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${DEMO_NS}
  labels: {demo: advanced}
spec:
  restartPolicy: Never
  containers:
${ctrs}
EOF
)
  rc=$?
  [ $rc -eq 0 ] && got=ADMIT || got=BLOCK
  report "$n" "$want" "$got" "$label" "$out"
  kubectl -n "$DEMO_NS" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
}

# case_ctrl <n> <expect> <label> <kind: deployment|cronjob> <image>
case_ctrl() {
  local n=$1 want=$2 label=$3 kind=$4 img=$5
  # SEPARATE `local`, deliberately. Bash expands the WHOLE local command line before any
  # of its assignments take effect, so `name="adv-${n}"` on the same line reads an $n that
  # does not exist yet -- and under `set -u` that is a fatal "unbound variable", not an
  # empty string. case_pod above splits it for the same reason.
  local name="adv-${n}" out rc got
  if [ "$kind" = deployment ]; then
    out=$(kubectl apply -f - 2>&1 <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: ${name}, namespace: ${DEMO_NS}, labels: {demo: advanced}}
spec:
  replicas: 1
  selector: {matchLabels: {app: ${name}}}
  template:
    metadata: {labels: {app: ${name}, demo: advanced}}
    spec:
      containers:
        - {name: c1, image: ${img}, command: ["sh","-c","sleep 604800"]}
EOF
)
  else
    out=$(kubectl apply -f - 2>&1 <<EOF
apiVersion: batch/v1
kind: CronJob
metadata: {name: ${name}, namespace: ${DEMO_NS}, labels: {demo: advanced}}
spec:
  schedule: "0 0 31 2 *"
  jobTemplate:
    spec:
      template:
        metadata: {labels: {demo: advanced}}
        spec:
          restartPolicy: Never
          containers:
            - {name: c1, image: ${img}, command: ["sh","-c","sleep 604800"]}
EOF
)
  fi
  rc=$?
  # A controller is admitted at CREATE; the POLICY is autogen-expanded onto its pod template, so
  # a denial surfaces here. If it does not, the pod-level denial shows up in the controller's
  # events instead -- check both rather than trusting the apply exit code alone.
  [ $rc -eq 0 ] && got=ADMIT || got=BLOCK
  if [ "$got" = ADMIT ] && [ "$want" = BLOCK ]; then
    sleep 8
    if kubectl -n "$DEMO_NS" describe "$kind" "$name" 2>/dev/null \
         | grep -qiE 'not signed|no approved exemption|denied the request'; then
      got=BLOCK; out="denied at the pod template (see ${kind}/${name} events)"
    fi
  fi
  report "$n" "$want" "$got" "$label" "$out"
  kubectl -n "$DEMO_NS" delete "$kind" "$name" --ignore-not-found >/dev/null 2>&1
}

report() {
  local n=$1 want=$2 got=$3 label=$4 out=$5
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1)); printf '  %2s  ok    %-6s %s\n' "$n" "$got" "$label"
  else
    FAIL=$((FAIL+1)); FAILED+=("$n")
    printf '  %2s  FAIL  got %-6s want %-6s %s\n' "$n" "$got" "$want" "$label"
    printf '%s\n' "$out" | sed 's/^/          | /' | head -6
  fi
}

echo "=== the five classes, each on its own ============================="
case_pod  1 ADMIT "class 1  self-built, signed"                     "$IMG_20"
case_pod  2 BLOCK "class 2  self-built, unsigned"                   "$IMG_10"
case_pod  3 ADMIT "class 3  self-built, unsigned, EXEMPTED"         "$IMG_30"
case_pod  4 BLOCK "class 4  vendor, not exempted"                   "$VENDOR_X"
case_pod  5 ADMIT "class 5  vendor, EXEMPTED"                       "$VENDOR_A"

echo
echo "=== the stated pod combinations ==================================="
case_pod  6 BLOCK "1,1,2    one unsigned self-built image"          "$IMG_20" "$IMG_20" "$IMG_10"
case_pod  7 ADMIT "1,1,3    signed + signed + approved"             "$IMG_20" "$IMG_20" "$IMG_30"
case_pod  8 BLOCK "4,1,5    one unapproved vendor image"            "$VENDOR_X" "$IMG_20" "$VENDOR_A"

echo
echo "=== the hole §10.3 opened, now closed ============================="
case_pod  9 BLOCK "3,2      THE SNEAKY POD (was ADMITTED in §10.3)" "$IMG_30" "$IMG_10"
case_pod 10 BLOCK "5,2      approved vendor + unsigned self-built"  "$VENDOR_A" "$IMG_10"
case_pod 11 ADMIT "1,5      signed app + approved vendor sidecar"   "$IMG_20" "$VENDOR_A"
case_pod 12 ADMIT "3,5      two approved images in one pod"         "$IMG_30" "$VENDOR_A"

echo
echo "=== multiple self-built registries ================================"
case_pod 13 ADMIT "1,6      two registries, both signed"            "$IMG_20" "$IMG_T2"
case_pod 14 BLOCK "6,2      registry 2 signed + registry 1 unsigned" "$IMG_T2" "$IMG_10"

echo
echo "=== autogen: does a PolicyException reach pod controllers? ========"
echo "    UNVERIFIED upstream. If 15 fails, the exception's matchConditions are not being"
echo "    rewritten for the controller's pod template, and every exempted Deployment is denied."
case_ctrl 15 ADMIT "deployment with an EXEMPTED vendor image"       deployment "$VENDOR_A"
case_ctrl 16 BLOCK "cronjob with an UNAPPROVED vendor image"        cronjob    "$VENDOR_X"

echo
echo "=================================================================="
printf 'RESULT  %d/%d passed\n' "$PASS" "$((PASS+FAIL))"
if [ "$FAIL" -ne 0 ]; then
  printf 'FAILED CASES: %s\n' "${FAILED[*]}"
  cat <<'EOM'

WHERE TO LOOK
  2, 6, 9, 10, 14 admitted    -> the signature policy is not matching. Check its scope
                                 expression compiled and uses `ref` (§11.4), and that the
                                 image really is under a configured prefix.
  1, 13 blocked               -> signature verification is failing on an image that IS signed.
                                 `notation verify` it locally, then check the admission
                                 controller can reach the registry (§7.4) and that the policy
                                 carries its own `credentials` block (§7.7).
  3, 5, 7, 11, 12 blocked     -> the exception is not matching. Its guard lists EVERY exemption
                                 on the cluster; if one is missing, a pod containing two
                                 approved images matches neither exception.
  4, 8, 16 admitted           -> the catch-all is not applying. Check its matchConditions and
                                 that features.policyExceptions.namespace is set (§7.1).
  15 blocked                  -> autogen does not rewrite a PolicyException's matchConditions.
                                 This is the open question; record the result either way.
EOM
  exit 1
fi
echo "All 16 cases behave as §11.1 requires."
