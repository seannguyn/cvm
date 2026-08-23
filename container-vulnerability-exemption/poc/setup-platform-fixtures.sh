#!/usr/bin/env bash
# One-time fixtures the PLATFORM model (50/51) needs on top of what §3-§11.5 already built.
#
#   source env.sh && bash setup-platform-fixtures.sh
#
# Three things, and only the first is interesting:
#
#   1. the unverified/ repository, holding the SAME image content as $IMG_30 under a different
#      repository name. This is the whole fixture difference between the two models: 30/31
#      exempts a non-compliant build in place, inside the signature policy's scope; 50/51
#      relocates it out of that scope and exempts it there. Same bytes, so case 3 compares.
#   2. read access to it for the admission controller's IRSA role. NOT optional -- without it
#      the allowlist policy never even gets to deny, and you debug the wrong thing. (Policy B
#      never reads a registry, but Policy A's cache and any future scan path do.)
#   3. the two extra namespaces the namespace-scoping cases need.
#
# Idempotent. Safe to re-run.
set -euo pipefail

: "${ECR:?source env.sh first}"; : "${REGION:?}"; : "${ACCOUNT_ID:?}"
: "${IMG_30:?}"; : "${IMG_30U:?}"; : "${UNVERIFIED_REPO:?}"
: "${DEMO_NS:?}"; : "${DEMO_NS2:?}"; : "${FOREIGN_NS:?}"; : "${POLICY_ARN:?}"

echo "== 1. the unverified/ repository =="
aws ecr describe-repositories --repository-names "$UNVERIFIED_REPO" --region "$REGION" >/dev/null 2>&1 \
  || aws ecr create-repository --repository-name "$UNVERIFIED_REPO" --region "$REGION" \
       --image-tag-mutability MUTABLE >/dev/null
echo "   ok: $UNVERIFIED_REPO"

echo "== 2. copy \$IMG_30's content to \$IMG_30U =="
# Pull-tag-push rather than a rebuild: the two fixtures MUST be the same bytes, or case 3 is
# comparing two different images across the two runs and the whole point is lost.
aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR" >/dev/null
docker pull -q "$IMG_30"
docker tag "$IMG_30" "$IMG_30U"
docker push -q "$IMG_30U"
echo "   ok: $IMG_30U"

# DELIBERATELY NOT SIGNED. A signature here would make case 3 pass for the wrong reason -- it
# would be admitted by Policy A rather than by the exemption, and the test would stop measuring
# the exemption route at all. Assert it, because "why is case 3 green" is exactly the question
# nobody re-asks six months later.
if notation verify "$IMG_30U" >/dev/null 2>&1; then
  echo "   FATAL: $IMG_30U carries a signature. It must NOT -- case 3 must be admitted by the"
  echo "          exemption, not by the signature policy. Delete the signature and re-run."
  exit 1
fi
echo "   ok: unsigned, as required"

echo "== 3. grant the admission controller read on unverified/* =="
# A managed policy holds at most 5 versions; drop the oldest non-default before adding one.
CURRENT=$(aws iam get-policy --policy-arn "$POLICY_ARN" --query 'Policy.DefaultVersionId' --output text)
aws iam get-policy-version --policy-arn "$POLICY_ARN" --version-id "$CURRENT" \
    --query 'PolicyVersion.Document' --output json > /tmp/ecr-policy.json
python3 - <<'PY'
import json
d = json.load(open("/tmp/ecr-policy.json"))
import os, re
acct, region = os.environ["ACCOUNT_ID"], os.environ["REGION"]
want = f"arn:aws:ecr:{region}:{acct}:repository/{os.environ['UNVERIFIED_REPO'].split('/')[0]}/*"
changed = False
for st in d["Statement"]:
    res = st.get("Resource")
    if res in ("*", None):
        continue
    res = res if isinstance(res, list) else [res]
    if any(r.startswith(f"arn:aws:ecr:{region}:{acct}:repository/") for r in res) and want not in res:
        st["Resource"] = res + [want]
        changed = True
json.dump(d, open("/tmp/ecr-policy.json", "w"))
print("   added" if changed else "   already present", want)
PY
VERSIONS=$(aws iam list-policy-versions --policy-arn "$POLICY_ARN" \
             --query 'Versions[?IsDefaultVersion==`false`].VersionId' --output text)
if [ "$(echo "$VERSIONS" | wc -w)" -ge 4 ]; then
  aws iam delete-policy-version --policy-arn "$POLICY_ARN" \
      --version-id "$(echo "$VERSIONS" | awk '{print $NF}')"
fi
aws iam create-policy-version --policy-arn "$POLICY_ARN" \
    --policy-document file:///tmp/ecr-policy.json --set-as-default >/dev/null
echo "   ok (IAM is eventually consistent, and imageVerifyCache may hold an old failure --"
echo "       restart the admission controller rather than wondering why the next run fails:"
echo "       kubectl -n kyverno rollout restart deploy -l app.kubernetes.io/component=admission-controller)"

echo "== 4. namespaces =="
for ns in "$DEMO_NS" "$DEMO_NS2" "$FOREIGN_NS"; do
  kubectl get ns "$ns" >/dev/null 2>&1 || kubectl create ns "$ns" >/dev/null
  echo "   ok: $ns"
done

echo
echo "DONE. Now:"
echo "  1. fill the CA into 50-platform-admission.yaml (see its header, PASTE-ROOT-CA-PEM-HERE)"
echo "  2. kubectl apply -f 50-platform-admission.yaml -f 51-appteam-exception.yaml"
echo "  3. bash run-platform-tests.sh 2>&1 | tee platform-tests.txt"
