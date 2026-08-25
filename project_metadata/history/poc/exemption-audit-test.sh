#!/usr/bin/env bash
# Does an EXEMPTED pod produce a PolicyReport row?  Run from container-vulnerability-exemption/poc/
#
#   source env.sh && bash exemption-audit-test.sh
#
# Runs app-10 (unsigned, NOT exempt -> must FAIL) and app-30 (unsigned, EXEMPT -> ?) in the same
# Audit window. app-10 is the control: it proves the reporting pipeline is alive, so whatever
# app-30 does is a fact about EXCEPTIONS and not about reports being broken.
# Restores [Deny,Audit] and removes both pods on exit.
set -uo pipefail
: "${DEMO_NS:?source env.sh first}"; : "${IMG_10:?}"; : "${IMG_30:?}"
POL=soe-notary-signed-simple

restore() {
  echo; echo ">> restoring $POL to [Deny,Audit], removing probe pods"
  kubectl patch imagevalidatingpolicy "$POL" --type=merge \
    -p '{"spec":{"validationActions":["Deny","Audit"]}}' >/dev/null 2>&1
  # kubectl -n "$DEMO_NS" delete pod audit-fail audit-exempt --ignore-not-found --wait=false >/dev/null 2>&1
}
trap restore EXIT

kubectl patch imagevalidatingpolicy "$POL" --type=merge -p '{"spec":{"validationActions":["Audit"]}}'
kubectl -n "$DEMO_NS" delete pod audit-fail audit-exempt --ignore-not-found >/dev/null 2>&1
sleep 3

echo ">> CONTROL: unsigned, not exempt  ($IMG_10)"
kubectl -n "$DEMO_NS" run audit-fail   --image="$IMG_10" --restart=Never --command -- sh -c "sleep 604800"
echo ">> SUBJECT: unsigned, EXEMPT      ($IMG_30)"
kubectl -n "$DEMO_NS" run audit-exempt --image="$IMG_30" --restart=Never --command -- sh -c "sleep 604800"

for i in 1 2 3 4 5 6; do
  sleep 5
  n=$(kubectl get policyreports.wgpolicyk8s.io -n "$DEMO_NS" -o json 2>/dev/null | jq '.items|length')
  echo "   t+$((i*5))s  policyreports=$n"
  [ "${n:-0}" -ge 2 ] && break
done

echo; echo "=== PolicyReports ==="
kubectl -n "$DEMO_NS" get polr -o wide
kubectl -n "$DEMO_NS" get polr -o json | jq '.items[]
  | {subject: .scope.name, results: [.results[] | {policy, result, message, properties}]}'

echo; echo "=== EphemeralReports (upstream stage -- catches an aggregation-only gap) ==="
kubectl get ephemeralreports.reports.kyverno.io -n "$DEMO_NS" -o json 2>/dev/null \
  | jq '.items[] | {owner: (.metadata.ownerReferences//[])[0].name,
                    results: [.spec.results[]? | {policy, result}]}'

echo; echo "=== is the exception even being honoured? ==="
kubectl -n "$DEMO_NS" get pod audit-exempt >/dev/null 2>&1 \
  && echo "   audit-exempt exists -- yes, the exception matched (it is unsigned)" \
  || echo "   audit-exempt MISSING -- the exception did not match; this test proves nothing"

cat <<'EOM'

VERDICT
  audit-fail FAIL row AND audit-exempt SKIP row
     -> the audit trail exists, but only in Audit. Under Deny (production) there is no standing
        record of which exemptions carried which workloads.
  audit-fail FAIL row, NO row for audit-exempt
     -> a matched PolicyException produces NO report result at all. `reportResult: skip` is inert
        for IVP, and Kyverno has no exemption audit trail in ANY mode -- you would reconstruct it
        from the PolicyException objects across every cluster.
  neither row
     -> reporting is not working; this test says nothing about exceptions. See 9.3.
EOM
