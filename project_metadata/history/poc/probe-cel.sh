#!/usr/bin/env bash
# Which CEL does THIS Kyverno actually compile?  Run from container-vulnerability-exemption/poc/
#
#   source env.sh && bash probe-cel.sh 2>&1 | tee probe-cel.txt
#
# Creates nothing. Every candidate goes through `kubectl apply --dry-run=server`, which makes
# Kyverno compile the CEL and reject the policy if it does not typecheck.
#
# v2 -- the first version TRUNCATED the compiler error (a grep that stopped at "Invalid value:"),
# which hid the only useful part. This prints the whole thing.
#
# Three questions, in dependency order:
#   Q1  Does matchImageReferences[].expression compile ANYTHING on this build?  (Design C lives
#       or dies here, before any variable-name guessing.)
#   Q2  If it does, what is the image reference bound as?
#   Q3  What TYPE are the elements of images.containers?  (Design B needs to compare one to a
#       string literal; the v1 run proved they are not strings.)
set -uo pipefail

: "${ECR:?source env.sh first}"; : "${DEMO_CA:?}"
EXEMPT="${ECR}/soe-demo/app:3.0"
PREFIX="${ECR}/soe-demo/"

PEM=$(sed 's/^/            /' "$DEMO_CA")
PASS=(); FAIL=()

emit() {  # emit <where> <body>  -> a complete IVP on stdout
  local where=$1 body=$2
  echo "apiVersion: policies.kyverno.io/v1"
  echo "kind: ImageValidatingPolicy"
  echo "metadata: {name: probe-tmp}"
  echo "spec:"
  echo "  validationActions: [Audit]"
  echo "  evaluation: {admission: {enabled: true}, background: {enabled: false}}"
  echo "  matchConstraints:"
  echo "    resourceRules:"
  echo '      - apiGroups: [""]'
  echo '        apiVersions: ["v1"]'
  echo '        operations: ["CREATE"]'
  echo '        resources: ["pods"]'
  echo "  matchImageReferences:"
  if [ "$where" = match ]; then
    echo "    - expression: |-"
    echo "        $body"
  else
    echo "    - glob: \"${PREFIX}*\""
  fi
  echo "  credentials:"
  echo "    providers: [default, amazon]"
  echo "  attestors:"
  echo "    - name: notary"
  echo "      notary:"
  echo "        certs:"
  echo "          value: |"
  echo "$PEM"
  echo "  validations:"
  if [ "$where" = match ]; then
    echo '    - expression: "true"'
    echo "      message: probe"
  else
    echo "    - expression: |-"
    echo "        $body"
    echo "      message: probe"
  fi
}

try() {  # try <id> <where> <body...>
  local id=$1 where=$2; shift 2
  local body="$*" f out rc
  f=$(mktemp); emit "$where" "$body" > "$f"
  out=$(kubectl apply --dry-run=server -f "$f" 2>&1); rc=$?
  rm -f "$f"
  if [ $rc -eq 0 ]; then
    PASS+=("$id"); printf '  PASS  %-24s %s\n' "$id" "$body"
  else
    FAIL+=("$id"); printf '  fail  %-24s %s\n' "$id" "$body"
    # FULL error, indented. This is the part v1 threw away.
    printf '%s\n' "$out" | sed 's/^/          | /'
  fi
}

echo
echo "############ Q1. Does matchImageReferences[].expression compile AT ALL? ############"
echo "# If even a constant fails, the field is inert on this build and Design C is dead"
echo "# regardless of variable names. This is the load-bearing test."
try const-true      match "true"
try const-false     match "false"

echo
echo "############ Q2. If it compiles, what is the reference bound as? ############"
try v-image         match "image.startsWith('${PREFIX}')"
try v-ref           match "ref.startsWith('${PREFIX}')"
try v-imageRef      match "imageRef.startsWith('${PREFIX}')"
try v-reference     match "reference.startsWith('${PREFIX}')"
try v-image-dot     match "image.registry == '${ECR}'"
try v-image-call    match "image.registry() == '${ECR}'"

echo
echo "############ Q3. What are the elements of images.containers? ############"
echo "# control first -- this MUST pass, it is what the demo already ships."
try control         validations "images.containers.all(i, verifyImageSignatures(i, [attestors.notary]) > 0)"

echo "# --- Q3a. is images.containers a LIST or a MAP? ---"
echo "# If it is map<string,Image> keyed by CONTAINER NAME, then .all(i,...) binds i to the KEY."
echo "# That single fact would explain every v1 failure: the key is a container name, so comparing"
echo "# it to an image reference is meaningless even where it typechecks. Indexing settles it."
try map-index       validations "images.containers.all(i, verifyImageSignatures(images.containers[i], [attestors.notary]) > 0)"
try list-size       validations "size(images.containers) >= 0 && images.containers.all(i, verifyImageSignatures(i, [attestors.notary]) > 0)"

echo "# --- Q3b. compare the bound element to a string, WITHOUT the verify clause ---"
echo "# Isolates the comparison. If this fails and control passes, the element is not a string."
try i-eq-alone      validations "images.containers.all(i, i == '${EXEMPT}')"
try i-in-alone      validations "images.containers.all(i, i in ['${EXEMPT}'])"
try i-startswith    validations "images.containers.all(i, i.startsWith('${PREFIX}'))"

echo "# --- Q3c. field / method accessors on the bound element ---"
for f in image reference ref name identifier registry repository tag digest; do
  try "i-dot-$f"    validations "images.containers.all(i, verifyImageSignatures(i, [attestors.notary]) > 0 || i.${f} == '${EXEMPT}')"
done
try i-call-registry validations "images.containers.all(i, verifyImageSignatures(i, [attestors.notary]) > 0 || i.registry() == '${ECR}')"
try i-string        validations "images.containers.all(i, verifyImageSignatures(i, [attestors.notary]) > 0 || string(i) == '${EXEMPT}')"

echo "# --- Q3d. does a field of the element feed verifyImageSignatures? ---"
echo "# If i is an Image object, one of these is the string the verifier wants."
for f in image reference name; do
  try "verify-i-$f" validations "images.containers.all(i, verifyImageSignatures(i.${f}, [attestors.notary]) > 0)"
done

echo
echo "############ Q5. The spec.variables allowlist proposal ############"
echo "# Design B with the exemption list in spec.variables instead of inline literals."
echo "# Everything hinges on whether an element of images.containers can be compared to a"
echo "# STRING list at all -- Q3 suggests not, but `in` is a different operator, so test it."
try_vars() {  # try_vars <id> <validation-body>
  local id=$1; shift
  local body="$*" f out rc
  f=$(mktemp)
  { emit validations "$body"
    echo "  variables:"
    echo "    - name: allowedUnsignedImages"
    echo "      expression: >-"
    echo "        [\"${EXEMPT}\"]"
  } > "$f"
  out=$(kubectl apply --dry-run=server -f "$f" 2>&1); rc=$?
  rm -f "$f"
  if [ $rc -eq 0 ]; then
    PASS+=("$id"); printf '  PASS  %-24s %s\n' "$id" "$body"
  else
    FAIL+=("$id"); printf '  fail  %-24s %s\n' "$id" "$body"
    printf '%s\n' "$out" | sed 's/^/          | /'
  fi
}

# does spec.variables compile at all on this build?
try_vars vars-unused    "images.containers.all(i, verifyImageSignatures(i, [attestors.notary]) > 0)"
# the proposal, verbatim in shape
try_vars vars-in-direct "images.containers.all(i, i in variables.allowedUnsignedImages || verifyImageSignatures(i, [attestors.notary]) > 0)"
# same, but reading a field off the element -- whichever Q3 found
for f in image reference ref name identifier; do
  try_vars "vars-in-$f"  "images.containers.all(i, i.${f} in variables.allowedUnsignedImages || verifyImageSignatures(i, [attestors.notary]) > 0)"
done
# and the string()-cast form
try_vars vars-in-string "images.containers.all(i, string(i) in variables.allowedUnsignedImages || verifyImageSignatures(i, [attestors.notary]) > 0)"
# the map-keyed form, if Q3a says containers is a map
try_vars vars-in-mapval "images.containers.all(i, images.containers[i] in variables.allowedUnsignedImages || verifyImageSignatures(images.containers[i], [attestors.notary]) > 0)"

echo
echo "############ Q6. Kyverno's OWN answer: fine-grained exceptions ############"
echo "# Upstream shipped exactly this problem's fix in 1.16 (epic kyverno#13654, KDP#77):"
echo "#   PolicyException gains  spec.images: [...]"
echo "#   and the POLICY reads it back as  exceptions.allowedImages  inside CEL."
echo "# Every documented example is a ValidatingPolicy. Whether the ivpol CEL environment"
echo "# binds 'exceptions' at all is undocumented -- so ask the compiler."
echo "# If this works it beats both Design B and Design C: per-image granularity AND the"
echo "# exemption list stays in a PolicyException (separate RBAC, expiry, audit trail)."

echo "--- does the PolicyException CRD on this build even have spec.images?"
for crd in policyexceptions.policies.kyverno.io policyexceptions.kyverno.io; do
  echo "    $crd:"
  kubectl get crd "$crd" -o json 2>/dev/null \
    | jq -r '.spec.versions[-1].schema.openAPIV3Schema.properties.spec.properties | keys | join(", ")' \
    2>/dev/null | sed 's/^/      /' || echo "      (not installed)"
done
echo "    -> looking for 'images' and 'allowedValues' in that list."

try exc-exists      validations "size(exceptions.allowedImages) >= 0 && images.containers.all(i, verifyImageSignatures(i, [attestors.notary]) > 0)"
try exc-in-direct   validations "images.containers.all(i, i in exceptions.allowedImages || verifyImageSignatures(i, [attestors.notary]) > 0)"
for f in image reference name identifier; do
  try "exc-in-$f"   validations "images.containers.all(i, i.${f} in exceptions.allowedImages || verifyImageSignatures(i, [attestors.notary]) > 0)"
done
try exc-in-mapval   validations "images.containers.all(i, images.containers[i] in exceptions.allowedImages || verifyImageSignatures(images.containers[i], [attestors.notary]) > 0)"

echo
echo "############ Q4. Fallbacks that need neither of the above ############"
echo "# Resource-level matchConditions are known to work (the catch-all uses them). Can a"
echo "# per-IMAGE exemption be expressed there at all? It cannot -- but confirm object.spec"
echo "# is reachable, because Design A's manifests still rely on it."
f=$(mktemp)
{ emit validations "images.containers.all(i, verifyImageSignatures(i, [attestors.notary]) > 0)"
  echo "  matchConditions:"
  echo "    - name: probe-resource-level"
  echo "      expression: |-"
  echo "        object.spec.containers.all(c, c.image != '${EXEMPT}')"
} > "$f"
out=$(kubectl apply --dry-run=server -f "$f" 2>&1); rc=$?; rm -f "$f"
if [ $rc -eq 0 ]; then PASS+=("matchConditions-object"); echo "  PASS  matchConditions-object   object.spec.containers[].image is readable"
else FAIL+=("matchConditions-object"); echo "  fail  matchConditions-object"; printf '%s\n' "$out" | sed 's/^/          | /'; fi

echo
echo "================================================================"
printf 'compiled: %s\n' "${PASS[*]:-none}"
printf 'rejected: %s\n' "${FAIL[*]:-none}"
cat <<'EOM'

DECIDING THE DESIGN

  const-true FAILS
     -> matchImageReferences[].expression is not usable on this build. DESIGN C IS OUT.
        Go to Q3: if any i-* passed, Design B works. If none did, Design A is the answer.

  const-true PASSES, some v-* passes
     -> Design C is alive; use the form that compiled and set MIR_FORM accordingly.

  any i-<field> PASSES
     -> Design B is available: exemptions inlined per-image next to verifyImageSignatures,
        using that field. Costs the polex audit trail and engine-enforced expiry.

  control FAILS
     -> stop. Something unrelated is wrong and nothing above means anything.

  map-index PASSES (and list-size fails)
     -> images.containers is map<string, Image> keyed by CONTAINER NAME. `.all(i, ...)` binds i
        to the key. Every v1 failure follows from this and nothing else: you were comparing a
        container name to an image reference. The exemption test has to read the VALUE --
        images.containers[i] -- not the loop variable. See vars-in-mapval.

  i-eq-alone / i-in-alone / i-startswith all FAIL but control PASSES
     -> the bound element is not a string. Whatever verifyImageSignatures accepts, `==` and `in`
        against a string literal do not typecheck against it. Read the printed error: it names
        the actual type, which is the single most useful line in this whole run.

  any vars-in-* PASSES
     -> the spec.variables allowlist design works. It is Design B with the list in a variable
        (or later a ConfigMap), and on 1.18.2 it costs little: expiresAt and properties do not
        exist on this version, and the polex skip trail is invisible under Deny anyway.
        COST TO MEASURE FIRST: it needs matchImageReferences glob "**", so Kyverno attempts
        signature verification on EVERY vendor image -- four registry round trips each, on the
        pod-create path, against registries you do not control.

  any exc-in-* PASSES
     -> USE THIS AND STOP READING. It is Kyverno's own supported answer to "an exception
        exempts the whole resource": the exemption list lives in PolicyException.spec.images,
        the policy consults it per image as exceptions.allowedImages, and you keep the
        PolicyException object -- separate RBAC, its own lifecycle, its own audit trail --
        instead of inlining literals in the policy spec. Shipped 1.16 for ValidatingPolicy;
        this probe is checking whether ivpol got it too.
        THEN CHECK kyverno#16053: allowedImages ACCUMULATE across every matching exception,
        and a full-exemption exception is silently overridden by an image-scoped one. Fixed
        2026-07-28; confirm the fix is in 1.18.2 before relying on multiple exceptions.

  exc-exists FAILS
     -> the ivpol CEL environment does not bind `exceptions`. Fine-grained exceptions are
        ValidatingPolicy-only on this build. Fall back to Q5 (spec.variables) or Design A,
        and treat this as the thing to re-test when you move to 1.19.

  vars-unused PASSES but every vars-in-* FAILS
     -> spec.variables works, but an images.containers element cannot be matched against a
        string list. The allowlist has to be expressed some other way, or Design A.
EOM
