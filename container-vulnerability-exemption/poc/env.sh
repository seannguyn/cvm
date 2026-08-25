export AWS_REGION="ap-southeast-2"
export REGION="$AWS_REGION"
export CLUSTER="cve-kyverno-demo"
export ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
export ECR="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

# The two image populations. The SOE prefix is what the signature policy globs on.
export SOE_REPO="soe-demo/app"          # self-built: must be signed
export VENDOR_REPO="vendor-demo/tool"   # third-party: will never be signed
export VENDOR_REPO2="vendor-demo/sidecar"
export SOE_PREFIX="${ECR}/soe-demo/"

export IMG_10="${ECR}/${SOE_REPO}:1.0"      # unsigned
export IMG_20="${ECR}/${SOE_REPO}:2.0"      # SIGNED
export IMG_30="${ECR}/${SOE_REPO}:3.0"      # unsigned, exempted in §11
export VENDOR_A="${ECR}/${VENDOR_REPO}:3.0"     # §12: 3.0's content, as a vendor image
export VENDOR_B="${ECR}/${VENDOR_REPO2}:1.0"    # §12: a second exempt vendor
export VENDOR_X="public.ecr.aws/docker/library/busybox:1.36"   # never exempt

export KYVERNO_CHART_VERSION="3.9.0-rc.4"
export EXC_NS="kyverno-exceptions"
export DEMO_NS="demo"
export DEMO_CA="/Users/emberlab/Library/Mobile Documents/com~apple~CloudDocs/container-vulns-mangement/container-vulnerability-exemption/out/pki/root.crt"
export REF_20="891377217246.dkr.ecr.ap-southeast-2.amazonaws.com/soe-demo/app@sha256:c9738028d19da52bf24d4f13c80944f818d308a67f6fd1276d8ef5cecca82ff8"
export POLICY_ARN="arn:aws:iam::891377217246:policy/cve-kyverno-demo-kyverno-ecr-read"
export KYVERNO_ROLE_ARN="arn:aws:iam::891377217246:role/cve-kyverno-demo-kyverno-admission-ecr"
export SOE_REPO2="soe-team2/app"
export SOE_PREFIX2="${ECR}/soe-team2/"
export IMG_T2="${ECR}/${SOE_REPO2}:1.0"

# --- §17 THE PLATFORM MODEL (50/51) ---------------------------------------------------------
# The bake-off runs BOTH admission models against the SAME image population, so run-*-tests.sh
# share this file and only the manifests differ. One fixture cannot be shared, and the reason
# IS the finding rather than a workaround:
#
#   30/31 exempts a non-compliant self-built build IN PLACE, at soe-demo/app:3.0 -- an unsigned
#         image inside the signature policy's own scope, carved out of it by an expression.
#   50/51 cannot express that and will not: the signed prefix is an ACL boundary, so a build
#         that fails compliance is RELOCATED to unverified/ and exempted there like a vendor
#         image. Same bytes, different repository, and the signature policy stays static.
#
# So IMG_30 and IMG_30U are the same content pushed twice. Case 3 is "the non-compliant build
# is admitted by exemption" in both runs; only the route differs.
export UNVERIFIED_REPO="unverified/app"
export UNVERIFIED_PREFIX="${ECR}/unverified/"
export IMG_30U="${ECR}/${UNVERIFIED_REPO}:3.0"      # == IMG_30's content, relocated. UNSIGNED.

# Second namespace, so the namespace clause on 51 is exercised in both directions: the harness
# proves an approved image is admitted in demo-uat and DENIED in a namespace the exemption does
# not name. 30/31 has no vocabulary for this -- its exceptions are cluster-wide.
export DEMO_NS2="demo-uat"
export FOREIGN_NS="other-team"

# A platform image, for the case 30/31 cannot express: infrastructure running in an APP
# namespace (an injected sidecar, a node agent). Read the real value off the cluster rather
# than trusting this one -- the EKS addon account differs by region AND partition:
#   kubectl -n kube-system get ds,deploy -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u
export PLATFORM_IMG="602401143452.dkr.ecr.${REGION}.amazonaws.com/eks/coredns:v1.11.3"
