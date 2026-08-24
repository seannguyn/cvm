#!/usr/bin/env bash
# SIMPLE MODE against the live cluster — and the hole it exists to demonstrate.
#
#   source env.sh
#   (cd ../unikube && python3 scripts/kyverno_render.py --cluster poc/demo --out-dir /tmp/k)
#   kubectl apply -f /tmp/k/poc/demo/policy-exception/
#   bash run-tests.sh 2>&1 | tee tests.txt
#
# WHAT THIS HARNESS IS FOR, and it is NOT "does simple mode work".
#
# Simple mode is ONE ImageValidatingPolicy globbing "**": every image must be signed, and a
# PolicyException is the only other answer. The first five cases show it doing its job. The
# sixth shows why it cannot be run on a fleet, and that case is the entire point of the file.
#
# THE SNEAKY POD (case 6) IS EXPECTED TO BE **ADMITTED**. A PolicyException skips a policy for
# the whole RESOURCE, and in simple mode there is exactly one policy — so an exception written
# for an approved image also switches off signature verification for everything shipped beside
# it. `$IMG_30` is approved; `$IMG_10` is an unsigned self-built image that nobody approved;
# put them in one pod and both are admitted.
#
# So case 6 asserting ADMIT is the demonstration succeeding, not a bug being tolerated. A run
# where case 6 FAILS means the hole did not reproduce, and that is worth knowing too — it would
# mean simple mode is no longer the shape demo.md §10.3 describes.
#
# demo.md §10.3 is the narrative version; §11 is the fix, and poc/run-advanced-tests.sh is the
# harness that proves it. Compare the two output files: this one ends with a hole, that one
# closes it.
#
# Creates and deletes pods in $DEMO_NS. Leaves nothing behind.
set -uo pipefail

: "${DEMO_NS:?source env.sh first}"; : "${IMG_10:?}"; : "${IMG_20:?}"; : "${IMG_30:?}"
: "${VENDOR_A:?}"; : "${VENDOR_X:?}"

PASS=0; FAIL=0; FAILED=()

cleanup() {
  kubectl -n "$DEMO_NS" delete pod -l demo=simple --ignore-not-found --wait=false >/dev/null 2>&1
}
trap cleanup EXIT
cleanup; sleep 2

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

# case_pod <n> <ADMIT|BLOCK> <label> <image...>
case_pod() {
  local n=$1 want=$2 label=$3; shift 3
  local name="simple-${n}" ctrs="" i=0 out rc got
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
  labels: {demo: simple}
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

echo "=== simple mode does what it claims ==============================="
echo "    ONE policy, glob \"**\": every image must be signed, or carry an exception."
case_pod 1 ADMIT "signed self-built image"                     "$IMG_20"
case_pod 2 BLOCK "unsigned self-built image"                   "$IMG_10"
case_pod 3 ADMIT "unsigned self-built image, EXEMPTED"         "$IMG_30"
case_pod 4 BLOCK "vendor image, not exempted"                  "$VENDOR_X"
case_pod 5 ADMIT "vendor image, EXEMPTED"                      "$VENDOR_A"

echo
echo "=== §10.3 THE HOLE — expected to be ADMITTED ======================"
cat <<'EOM'
    An exception skips a policy for the whole RESOURCE, and simple mode has exactly one
    policy. So the exception written for the approved image also switches signature
    verification off for the unsigned one shipped beside it. BOTH are admitted.

    Case 6 asserting ADMIT is the demonstration WORKING. It is the reason the two-policy
    models exist (poc/kyverno_render_advanced.py), and run-advanced-tests.sh case 9 is the
    same pod, denied.
EOM
case_pod 6 ADMIT "THE SNEAKY POD: exempted + unsigned, both admitted" "$IMG_30" "$IMG_10"

echo
echo "=================================================================="
printf 'RESULT  %d/%d passed\n' "$PASS" "$((PASS+FAIL))"
if [ "$FAIL" -ne 0 ]; then
  printf 'FAILED CASES: %s\n' "${FAILED[*]}"
  cat <<'EOM'

WHERE TO LOOK
  2, 4 admitted    -> the policy is not matching, or not enforcing. Check validationActions is
                      ["Deny","Audit"] on the cluster (editing a heredoc does not change the
                      cluster), and that the policy carries its own `credentials` block -- a
                      401 is an evaluation ERROR, and under failurePolicy: Ignore an error
                      SKIPS the policy, so the image is admitted unverified. demo.md §7.7.
  1 blocked        -> verification is failing on an image that IS signed. `notation verify` it
                      locally, then check the controller can reach ECR (§7.4).
  3, 5 blocked     -> the exception is not matching. features.policyExceptions.enabled
                      DEFAULTS TO FALSE, and .namespace must be kyverno-exceptions (§7.1) --
                      an exception that applies cleanly and does nothing looks exactly like
                      this.
  6 BLOCKED        -> the hole did NOT reproduce, which means this is no longer the shape
                      demo.md §10.3 describes. Do not "fix" it: find out what changed, because
                      the §11 argument is built on this behaviour.
EOM
  exit 1
fi
cat <<'EOM'

All 5 correctness cases pass, and the §10.3 hole reproduced.

  Simple mode enforces signatures and it is NOT safe on a fleet: one approved image carries
  anything shipped with it. Sidecar injection is automatic, so that is a general bypass rather
  than an edge case.

  Next: render the same cluster with --advanced and run run-advanced-tests.sh. Case 9 there is
  this exact pod, and it is denied.
EOM
