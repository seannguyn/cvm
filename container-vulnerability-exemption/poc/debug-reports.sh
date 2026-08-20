#!/usr/bin/env bash
# Why is `kubectl get polr` empty?  Run from container-vulnerability-exemption/poc/
#
#   source env.sh && bash debug-reports.sh 2>&1 | tee reports-debug.log
#
# Collects the facts, then runs ONE experiment that discriminates between:
#   H1  reports record VIOLATIONS. A passing pod has none, and a failing pod is denied so it
#       never exists to carry one. => Audit-only + an unsigned pod WILL produce a report.
#   H2  report generation is broken for ImageValidatingPolicy on this build.
#       => nothing appears even then.
#
# Restores the policy to [Deny,Audit] and deletes its test pod on exit.
set -uo pipefail

: "${DEMO_NS:?source env.sh first}"; : "${IMG_10:?}"; : "${IMG_20:?}"
POL=soe-notary-signed-simple
TESTPOD=report-probe

hr() { printf '\n=== %s %s\n' "$1" "$(printf '=%.0s' $(seq 1 $((66 - ${#1}))))"; }

hr "1. versions and controllers"
kubectl -n kyverno get deploy -o custom-columns=\
NAME:.metadata.name,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image
kubectl version --output=json 2>/dev/null | jq -r '.serverVersion.gitVersion' 2>/dev/null

hr "2. reporting-related flags actually on the pods"
for d in kyverno-admission-controller kyverno-reports-controller kyverno-background-controller; do
  echo "--- $d"
  kubectl -n kyverno get deploy "$d" \
    -o jsonpath='{range .spec.template.spec.containers[0].args[*]}{@}{"\n"}{end}' 2>/dev/null \
    | grep -iE 'report|reporting|background' || echo "   (no report-related args)"
done

hr "3. the policy as the CLUSTER has it"
kubectl get imagevalidatingpolicy "$POL" -o jsonpath='{.spec.validationActions}{"\n"}'
kubectl get imagevalidatingpolicy "$POL" -o jsonpath='{.spec.evaluation}{"\n"}'
kubectl get imagevalidatingpolicy "$POL" -o jsonpath='{.status}{"\n"}' | head -c 600; echo

hr "4. report CRDs served"
kubectl api-resources 2>/dev/null | grep -iE 'policyreport|ephemeralreport' || echo "  NONE FOUND"

hr "4b. rule out kyverno#16153 -- was a native VAP generated from this policy?"
# #16153: when Kyverno GENERATES a native ValidatingAdmissionPolicy from a CEL ValidatingPolicy,
# the API SERVER evaluates it, Kyverno never sees the result, and no report is written.
# That path cannot apply to an ImageValidatingPolicy -- a native VAP is pure CEL with no
# registry client, so verifyImageSignatures() can only run in Kyverno's own engine. This
# section proves it rather than asserting it: expect NO VAP tracing back to $POL.
kubectl get validatingadmissionpolicies.admissionregistration.k8s.io 2>/dev/null \
  -o custom-columns=NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].kind,OWNERNAME:.metadata.ownerReferences[0].name \
  | grep -iE "NAME|kyverno|ivpol|$POL" || echo "  (no VAPs -- expected; IVP is never offloaded to a native VAP)"
echo "--- does the IVP even have a VAP-generation knob?"
kubectl get crd imagevalidatingpolicies.policies.kyverno.io -o json 2>/dev/null \
  | jq -r '[.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.autogen.properties | keys[]] | join(", ")' \
  2>/dev/null || echo "  (could not read CRD)"
echo "   -> expect only: podControllers.  ValidatingPolicy is the type that generates VAPs."

hr "5. resourceFilters -- is the demo namespace excluded?"
kubectl -n kyverno get cm kyverno -o jsonpath='{.data.resourceFilters}{"\n"}' 2>/dev/null \
  | tr ']' ']\n' | grep -iE "\[\*,${DEMO_NS}|\[Pod" || echo "  (nothing matching Pod or ${DEMO_NS})"

hr "6. BEFORE -- current reports at both stages"
echo "--- EphemeralReports (admission stage, reports.kyverno.io)"
kubectl get ephemeralreports.reports.kyverno.io -A 2>&1 | head -20
echo "--- PolicyReports (aggregated, wgpolicyk8s.io)"
kubectl get policyreports.wgpolicyk8s.io -A 2>&1 | head -20
kubectl get clusterpolicyreports.wgpolicyk8s.io 2>&1 | head -5

hr "7. EXPERIMENT -- Audit only, then admit a VIOLATING pod"
echo "The unsigned image is admitted under Audit, so the violation has a resource to attach to."
restore() {
  echo
  echo ">> restoring $POL to [Deny,Audit] and removing $TESTPOD"
  kubectl patch imagevalidatingpolicy "$POL" --type=merge \
    -p '{"spec":{"validationActions":["Deny","Audit"]}}' >/dev/null 2>&1
  kubectl -n "$DEMO_NS" delete pod "$TESTPOD" --ignore-not-found --wait=false >/dev/null 2>&1
}
trap restore EXIT

kubectl patch imagevalidatingpolicy "$POL" --type=merge \
  -p '{"spec":{"validationActions":["Audit"]}}'
sleep 5
kubectl -n "$DEMO_NS" delete pod "$TESTPOD" --ignore-not-found >/dev/null 2>&1

echo ">> creating $TESTPOD with the UNSIGNED image ($IMG_10)"
kubectl -n "$DEMO_NS" run "$TESTPOD" --image="$IMG_10" --restart=Never \
  --command -- sh -c "sleep 300"
echo ">> pod create exit: $?  (0 = admitted, which is expected under Audit)"

for i in 1 2 3 4 5 6; do
  sleep 5
  n=$(kubectl get policyreports.wgpolicyk8s.io -n "$DEMO_NS" -o json 2>/dev/null | jq '.items|length')
  e=$(kubectl get ephemeralreports.reports.kyverno.io -n "$DEMO_NS" -o json 2>/dev/null | jq '.items|length')
  echo "   t+$((i*5))s  ephemeral=$e  policyreports=$n"
  [ "${n:-0}" -gt 0 ] && break
done

hr "8. AFTER -- reports at both stages"
echo "--- EphemeralReports"
kubectl get ephemeralreports.reports.kyverno.io -n "$DEMO_NS" -o json 2>/dev/null \
  | jq '.items[] | {name:.metadata.name, owner:(.metadata.ownerReferences//[])[0].name,
                    results:[.spec.results[]? | {policy,rule,result}]}'
echo "--- PolicyReports"
kubectl get policyreports.wgpolicyk8s.io -n "$DEMO_NS" -o json 2>/dev/null \
  | jq '.items[] | {name:.metadata.name, subject:(.scope.name//"-"),
                    results:[.results[]? | {policy,rule,result,message}]}'

hr "9. reports-controller log"
kubectl -n kyverno logs deploy/kyverno-reports-controller --tail=120 2>&1 \
  | grep -iE 'ivpol|imagevalidating|report|error|panic' | tail -40

hr "10. admission-controller log for the probe"
kubectl -n kyverno logs deploy/kyverno-admission-controller --tail=200 2>&1 \
  | grep -iE "$TESTPOD|$POL|ivpol|report" | tail -30

hr "VERDICT"
cat <<'EOM'
Read section 8:

  PolicyReports NON-EMPTY, with result=fail for report-probe
      -> H1 CONFIRMED. Reports record violations. [Deny,Audit] can never show you one for
         this policy: a passing pod has no violation, and a failing pod is denied so no
         resource exists to carry the report. Nothing is broken. To SEE reports, run the
         policy in Audit for a while, or rely on the denial message + controller log.

  EphemeralReports non-empty but PolicyReports empty
      -> aggregation is not running. Check section 9 for reports-controller errors, and
         confirm features.aggregateReports.enabled / policyReports.enabled are true.

  BOTH empty
      -> H2. Admission-side reporting never fired for this ImageValidatingPolicy even with a
         real violation on an admitted resource. That is a genuine bug worth filing against
         kyverno/kyverno with sections 1, 2, 3 and 9 of this log attached.
EOM
