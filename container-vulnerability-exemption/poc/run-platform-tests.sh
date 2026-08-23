#!/usr/bin/env bash
# The §11 admission matrix, against the live cluster, for the PLATFORM model (50/51).
#
#   source env.sh && bash setup-platform-fixtures.sh      # once: the unverified/ repo + ns
#   source env.sh && bash run-platform-tests.sh 2>&1 | tee platform-tests.txt
#
# THE SIBLING OF run-advanced-tests.sh, AND DELIBERATELY THE SAME 16 CASES IN THE SAME ORDER.
# The bake-off is only a bake-off if both models face an identical matrix over an identical
# image population, so this file shares env.sh and changes exactly one fixture:
#
#   case 3   30/31 uses $IMG_30  (soe-demo/app:3.0)   -- non-compliant build exempted IN PLACE
#            50/51 uses $IMG_30U (unverified/app:3.0) -- same bytes, RELOCATED and exempted
#
# That is not a fudge to make the numbers match. 50/51 cannot exempt an image inside the
# signature policy's scope and will not: the prefix is an ACL boundary, so a build that fails
# compliance moves to a repository the signature policy does not own. Reviewers comparing the
# two runs should read case 3 as "both admit the non-compliant build by exemption; they differ
# in whether the exemption is a carve-out in a platform-owned policy or a relocation."
#
# Cases 17-21 have NO counterpart in run-advanced-tests.sh, because 30/31 has no vocabulary
# for them: exceptions there are cluster-wide, and there is no platform allowlist. They are
# reported separately and are NOT part of the 16-case score, so the headline numbers stay
# comparable.
#
# Creates and deletes pods in $DEMO_NS, $DEMO_NS2 and $FOREIGN_NS. Leaves nothing behind.
set -uo pipefail

: "${DEMO_NS:?source env.sh first}"; : "${IMG_10:?}"; : "${IMG_20:?}"; : "${IMG_30U:?}"
: "${VENDOR_A:?}"; : "${VENDOR_B:?}"; : "${VENDOR_X:?}"; : "${IMG_T2:?}"
: "${DEMO_NS2:?}"; : "${FOREIGN_NS:?}"; : "${PLATFORM_IMG:?}"

PASS=0; FAIL=0; FAILED=()
XPASS=0; XFAIL=0

ALL_NS=("$DEMO_NS" "$DEMO_NS2" "$FOREIGN_NS")

cleanup() {
  for ns in "${ALL_NS[@]}"; do
    kubectl -n "$ns" delete pod -l demo=platform --ignore-not-found --wait=false >/dev/null 2>&1
    kubectl -n "$ns" delete deploy,cronjob -l demo=platform --ignore-not-found >/dev/null 2>&1
  done
}
trap cleanup EXIT
cleanup; sleep 2

report() {
  local n=$1 want=$2 got=$3 label=$4 out=$5 bucket=${6:-core}
  if [ "$got" = "$want" ]; then
    if [ "$bucket" = core ]; then PASS=$((PASS+1)); else XPASS=$((XPASS+1)); fi
    printf '  %2s  ok    %-6s %s\n' "$n" "$got" "$label"
  else
    if [ "$bucket" = core ]; then FAIL=$((FAIL+1)); FAILED+=("$n"); else XFAIL=$((XFAIL+1)); fi
    printf '  %2s  FAIL  got %-6s want %-6s %s\n' "$n" "$got" "$want" "$label"
    printf '%s\n' "$out" | sed 's/^/          | /' | head -6
  fi
}

# case_pod <n> <ADMIT|BLOCK> <label> [--ns <namespace>] [--bucket <core|extra>] <image...>
case_pod() {
  local n=$1 want=$2 label=$3; shift 3
  local ns="$DEMO_NS" bucket=core
  while [ $# -gt 0 ]; do
    case "$1" in
      --ns) ns=$2; shift 2 ;;
      --bucket) bucket=$2; shift 2 ;;
      *) break ;;
    esac
  done
  local name="plat-${n}" ctrs="" i=0 out rc got
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
  namespace: ${ns}
  labels: {demo: platform}
spec:
  restartPolicy: Never
  containers:
${ctrs}
EOF
)
  rc=$?
  [ $rc -eq 0 ] && got=ADMIT || got=BLOCK
  report "$n" "$want" "$got" "$label" "$out" "$bucket"
  kubectl -n "$ns" delete pod "$name" --ignore-not-found --wait=false >/dev/null 2>&1
}

# case_ctrl <n> <expect> <label> <kind: deployment|cronjob> <image>
case_ctrl() {
  local n=$1 want=$2 label=$3 kind=$4 img=$5
  # SEPARATE `local`, deliberately -- bash expands the whole local command line before any of
  # its assignments take effect, so `name="plat-${n}"` on the same line reads an unset $n and
  # dies under `set -u`. Same reason case_pod splits it.
  local name="plat-${n}" out rc got
  if [ "$kind" = deployment ]; then
    out=$(kubectl apply -f - 2>&1 <<EOF
apiVersion: apps/v1
kind: Deployment
metadata: {name: ${name}, namespace: ${DEMO_NS}, labels: {demo: platform}}
spec:
  replicas: 1
  selector: {matchLabels: {app: ${name}}}
  template:
    metadata: {labels: {app: ${name}, demo: platform}}
    spec:
      containers:
        - {name: c1, image: ${img}, command: ["sh","-c","sleep 604800"]}
EOF
)
  else
    out=$(kubectl apply -f - 2>&1 <<EOF
apiVersion: batch/v1
kind: CronJob
metadata: {name: ${name}, namespace: ${DEMO_NS}, labels: {demo: platform}}
spec:
  schedule: "0 0 31 2 *"
  jobTemplate:
    spec:
      template:
        metadata: {labels: {demo: platform}}
        spec:
          restartPolicy: Never
          containers:
            - {name: c1, image: ${img}, command: ["sh","-c","sleep 604800"]}
EOF
)
  fi
  rc=$?
  # A controller is admitted at CREATE; the POLICY is autogen-expanded onto its pod template,
  # so a denial surfaces here. If it does not, the pod-level denial shows up in the
  # controller's events instead -- check both rather than trusting the apply exit code alone.
  [ $rc -eq 0 ] && got=ADMIT || got=BLOCK
  if [ "$got" = ADMIT ] && [ "$want" = BLOCK ]; then
    sleep 8
    if kubectl -n "$DEMO_NS" describe "$kind" "$name" 2>/dev/null \
         | grep -qiE 'not signed|approved exemption|neither platform infrastructure|denied the request'; then
      got=BLOCK; out="denied at the pod template (see ${kind}/${name} events)"
    fi
  fi
  report "$n" "$want" "$got" "$label" "$out"
  kubectl -n "$DEMO_NS" delete "$kind" "$name" --ignore-not-found >/dev/null 2>&1
}

echo "=== the five classes, each on its own ============================="
echo "    class 3 is \$IMG_30U (unverified/), where run-advanced-tests.sh uses \$IMG_30"
echo "    (soe-demo/). Same bytes; the relocation IS the design difference."
case_pod  1 ADMIT "class 1  self-built, signed"                     "$IMG_20"
case_pod  2 BLOCK "class 2  self-built, unsigned"                   "$IMG_10"
case_pod  3 ADMIT "class 3  self-built, unsigned, EXEMPTED"         "$IMG_30U"
case_pod  4 BLOCK "class 4  vendor, not exempted"                   "$VENDOR_X"
case_pod  5 ADMIT "class 5  vendor, EXEMPTED"                       "$VENDOR_A"

echo
echo "=== the stated pod combinations ==================================="
case_pod  6 BLOCK "1,1,2    one unsigned self-built image"          "$IMG_20" "$IMG_20" "$IMG_10"
case_pod  7 ADMIT "1,1,3    signed + signed + approved"             "$IMG_20" "$IMG_20" "$IMG_30U"
case_pod  8 BLOCK "4,1,5    one unapproved vendor image"            "$VENDOR_X" "$IMG_20" "$VENDOR_A"

echo
echo "=== the hole §10.3 opened, now closed ============================="
case_pod  9 BLOCK "3,2      THE SNEAKY POD (was ADMITTED in §10.3)" "$IMG_30U" "$IMG_10"
case_pod 10 BLOCK "5,2      approved vendor + unsigned self-built"  "$VENDOR_A" "$IMG_10"
case_pod 11 ADMIT "1,5      signed app + approved vendor sidecar"   "$IMG_20" "$VENDOR_A"
case_pod 12 ADMIT "3,5      two approved images in one pod"         "$IMG_30U" "$VENDOR_A"

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
printf 'CORE RESULT  %d/%d passed   (directly comparable with run-advanced-tests.sh)\n' \
       "$PASS" "$((PASS+FAIL))"

echo
echo "=== BEYOND THE MATRIX — what 50/51 can express and 30/31 cannot ==="
echo "    Scored SEPARATELY. These have no counterpart in the 16 cases, so folding them in"
echo "    would make the platform model look better by answering questions the other model"
echo "    was never asked."
echo
echo "  -- namespace scoping (51's first matchCondition) --"
case_pod 17 ADMIT "approved vendor image in \$DEMO_NS2"  --ns "$DEMO_NS2"   --bucket extra "$VENDOR_A"
case_pod 18 BLOCK "SAME image in \$FOREIGN_NS"           --ns "$FOREIGN_NS" --bucket extra "$VENDOR_A"
echo
echo "  -- the platform allowlist (50's matchConditions), in an APP namespace --"
echo "     NOTE: infrastructure in kube-system never reaches the webhook at all (the chart's"
echo "     config.resourceFilters excludes it), so this is the case that actually exercises"
echo "     the allowlist -- a platform image running where an app team's pods run."
case_pod 19 ADMIT "platform image alone, in \$DEMO_NS"      --bucket extra "$PLATFORM_IMG"
case_pod 20 ADMIT "platform image beside a SIGNED app"      --bucket extra "$IMG_20" "$PLATFORM_IMG"
case_pod 21 BLOCK "platform image beside an UNSIGNED app"   --bucket extra "$IMG_10" "$PLATFORM_IMG"

echo
echo "=================================================================="
printf 'CORE   %d/%d passed\n' "$PASS" "$((PASS+FAIL))"
printf 'EXTRA  %d/%d passed   (50/51-only capability; not comparable)\n' "$XPASS" "$((XPASS+XFAIL))"
if [ "$FAIL" -ne 0 ] || [ "$XFAIL" -ne 0 ]; then
  [ "$FAIL" -ne 0 ] && printf 'FAILED CORE CASES: %s\n' "${FAILED[*]}"
  cat <<'EOM'

WHERE TO LOOK
  2, 6, 9, 10, 14 admitted    -> the signature policy is not matching. Its scope is a plain
                                 GLOB list here (not an expression); check both self-built
                                 prefixes are globbed and that the image is really under one.
  1, 13 blocked               -> verification is failing on an image that IS signed.
                                 `notation verify` it locally, then check the controller can
                                 reach the registry (§7.4) and that Policy A carries its own
                                 `credentials` block (§7.7). A 401 is an evaluation ERROR, and
                                 under failurePolicy: Ignore an error SKIPS the policy -- so a
                                 missing credentials block fails OPEN, not closed.
  3, 5, 7, 11, 12 blocked     -> the exception is not matching. Three clauses must ALL hold:
                                 namespace, select, guard. Check $DEMO_NS is named in 51's
                                 namespace clause, and that the guard lists every exempt image.
  3 blocked, 5 admitted       -> the unverified/ fixture is missing or unreadable. Run
                                 setup-platform-fixtures.sh, and confirm the Kyverno IRSA
                                 policy grants read on the unverified/* repository too.
  4, 8, 16 admitted           -> the allowlist policy is not applying. Check its
                                 matchConditions and features.policyExceptions.namespace.
  15 blocked                  -> autogen does not rewrite a PolicyException's matchConditions.
                                 This is the open question; record the result either way.
  18 admitted                 -> the namespace clause is absent or wrong. An approval is then
                                 an approval EVERYWHERE, which is the finding, not a nit.
  19, 20 blocked              -> the platform prefix list is wrong for this cluster/region.
                                 Read the real image references off kube-system (see env.sh).
EOM
  exit 1
fi
echo "All 16 core cases behave as §11.1 requires, and the 5 extra cases hold."
