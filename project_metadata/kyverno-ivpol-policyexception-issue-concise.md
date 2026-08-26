# [Bug] `PolicyException.spec.images` is ignored by `ImageValidatingPolicy`, exempting all images in the resource

## Versions

Please disregard the out-of-date and incorrect version filled in as part of this Bug template. The below is correct technology and version

| Technology | Version |
|---|---|
| Kubernetes | v1.36 (EKS) |
| Kyverno | v1.19.0 |

## Description

A `PolicyException` referencing an `ImageValidatingPolicy` can carry `spec.images`, but the field does not narrow the exception.

If `matchConditions` matches a Pod, Kyverno skips the whole IVPOL for that Pod. An unrelated image in the same Pod is therefore never verified, even though it is not listed in `spec.images`.

This differs from `ValidatingPolicy`, where the same `spec.images` values are exposed as `exceptions.allowedImages` and validation continues for the other images.

| | `ValidatingPolicy` | `ImageValidatingPolicy` |
|---|---|---|
| `spec.images` | exposed as `exceptions.allowedImages` | accepted, not readable in CEL |
| unrelated image in the same Pod | still evaluated | not evaluated |
| mixed Pod | **DENY** | **ADMIT** |

## Reproduction Summary

One `ImageValidatingPolicy` requires every image to be signed by a generated self-signed CA. Neither test image is signed by it, so both are **denied** on their own. A `PolicyException` naming only `pause:3.9` is then added.

| Pod | Exception | Expected | Actual | Comment |
|---|---|---|---|---|
| `pause:3.9` | none | **❌ Deny** | **❌ Deny** | - |
| `busybox:1.29-4` | none | **❌ Deny** | **❌ Deny** | - |
| `pause:3.9` | `pause:3.9` | **✅ Admit** | **✅ Admit** | - |
| `busybox:1.29-4` | none | **❌ Deny** | **❌ Deny** | - |
| `pause:3.9` + `busybox:1.29-4` | only `pause:3.9` | **❌ Deny** | **✅ Admit** | **BUG:** `busybox:1.29-4` is unsigned, is NOT excepted, and is denied on its own — yet it is admitted alongside the excepted image. |

## Step-by-Step Reproduction

### Enable policy exceptions

Policy exceptions must be enabled and the namespace declared:

```yaml
features:
  policyExceptions:
    enabled: true
    namespace: kyverno-exceptions
```

```bash
kubectl create ns demo
kubectl create ns kyverno-exceptions
```

### 1. IVPOL: require every image to be signed

The CA is a throwaway. Its contents do not matter — nothing here is signed by anything.

```bash
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout /dev/null -out throwaway.crt \
  -days 3650 \
  -subj "/C=US/ST=CA/O=Example/CN=kyverno-issue-repro"

CERT="$(sed 's/^/            /' throwaway.crt)"

cat <<EOF | kubectl apply -f -
apiVersion: policies.kyverno.io/v1
kind: ImageValidatingPolicy
metadata:
  name: require-signed
spec:
  validationActions: [Deny]
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
  matchImageReferences:
    - glob: "**"
  attestors:
    - name: notary
      notary:
        certs:
          value: |
$CERT
  validations:
    - expression: >-
        images.containers.all(
          image,
          verifyImageSignatures(image, [attestors.notary]) > 0
        )
      message: image is not signed
EOF
```

Control — both images are denied independently:

```bash
kubectl -n demo run ctl-a --image=registry.k8s.io/pause:3.9 --restart=Never
kubectl -n demo run ctl-b --image=registry.k8s.io/e2e-test-images/busybox:1.29-4 --restart=Never
```

```text
Error from server: admission webhook "ivpol.validate.kyverno.svc-fail" denied the request: Policy require-signed failed: image is not signed
```

> `spec.credentials` is deliberately absent: `registry.k8s.io` serves anonymously, so no 401 can be mistaken for a failed verification.

### 2. Exception for `pause:3.9` only

```bash
kubectl apply -f - <<'EOF'
apiVersion: policies.kyverno.io/v1
kind: PolicyException
metadata:
  name: allow-pause
  namespace: kyverno-exceptions
spec:
  policyRefs:
    - name: require-signed
      kind: ImageValidatingPolicy
  images:
    - registry.k8s.io/pause:3.9
  matchConditions:
    - name: has-pause
      expression: >-
        object.spec.containers.exists(
          c,
          c.image == 'registry.k8s.io/pause:3.9'
        )
EOF

sleep 5   # an exception is not effective the instant `apply` returns
```

`pause:3.9` is admitted, and busybox on its own is still denied — so the policy is live and the exception does not cover it:

```bash
kubectl -n demo run exempt --image=registry.k8s.io/pause:3.9 --restart=Never
# pod/exempt created

kubectl -n demo run ctl-b2 --image=registry.k8s.io/e2e-test-images/busybox:1.29-4 --restart=Never
# Error from server: admission webhook "ivpol.validate.kyverno.svc-fail" denied the request:
# Policy require-signed failed: image is not signed
```

### 3. Mixed Pod

```bash
kubectl -n demo apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: mixed
  namespace: demo
spec:
  containers:
    - name: exempted
      image: registry.k8s.io/pause:3.9
    - name: other
      image: registry.k8s.io/e2e-test-images/busybox:1.29-4
      command: ["sh", "-c", "sleep 86400"]
EOF
```

Expected — `busybox:1.29-4` is not in `spec.images` and was denied on its own one command earlier:

```text
pod/mixed  ->  DENY
```

Actual:

```text
pod/mixed created
```

The exception matched the *resource*, the whole IVPOL was skipped, and `busybox:1.29-4` was never verified.

`spec.images` is also unreadable from the policy. This expression is rejected at policy-creation time:

```cel
images.containers.all(
  i,
  i in exceptions.allowedImages ||
  verifyImageSignatures(i, [attestors.notary]) > 0
)
```

```text
undeclared reference to 'exceptions'
```

Cleanup:

```bash
kubectl delete ns demo
kubectl -n kyverno-exceptions delete policyexception.policies.kyverno.io allow-pause
kubectl delete imagevalidatingpolicy require-signed
```

## Control: the same exception is granular on `ValidatingPolicy`

This `ValidatingPolicy` denies the same two images unless the image appears in `exceptions.allowedImages`.

```bash
kubectl create ns demo-vp

kubectl apply -f - <<'EOF'
apiVersion: policies.kyverno.io/v1
kind: ValidatingPolicy
metadata:
  name: require-image-exception
spec:
  validationActions: [Deny]
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
  validations:
    - expression: >-
        object.spec.containers.all(
          c,
          c.image in exceptions.allowedImages ||
          !(c.image in [
            'registry.k8s.io/pause:3.9',
            'registry.k8s.io/e2e-test-images/busybox:1.29-4'
          ])
        )
      message: image requires an explicit exception
EOF
```

Without an exception, both are denied:

```bash
kubectl -n demo-vp run ctl-a --image=registry.k8s.io/pause:3.9 --restart=Never
kubectl -n demo-vp run ctl-b --image=registry.k8s.io/e2e-test-images/busybox:1.29-4 --restart=Never
```

```text
Error from server: admission webhook "vpol.validate.kyverno.svc-fail" denied the request: Policy require-image-exception failed: image requires an explicit exception
```

The equivalent exception, again naming only `pause:3.9`:

```bash
kubectl apply -f - <<'EOF'
apiVersion: policies.kyverno.io/v1
kind: PolicyException
metadata:
  name: vp-allow-pause
  namespace: kyverno-exceptions
spec:
  policyRefs:
    - name: require-image-exception
      kind: ValidatingPolicy
  images:
    - registry.k8s.io/pause:3.9
  matchConditions:
    - name: has-pause
      expression: >-
        object.spec.containers.exists(
          c,
          c.image == 'registry.k8s.io/pause:3.9'
        )
EOF

sleep 5
```

`pause:3.9` alone is admitted:

```bash
kubectl -n demo-vp run vp-exempt --image=registry.k8s.io/pause:3.9 --restart=Never
# pod/vp-exempt created
```

The mixed Pod — identical in shape to step 3 — is denied:

```bash
kubectl -n demo-vp apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: vp-mixed
  namespace: demo-vp
spec:
  containers:
    - name: exempted
      image: registry.k8s.io/pause:3.9
    - name: other
      image: registry.k8s.io/e2e-test-images/busybox:1.29-4
      command: ["sh", "-c", "sleep 86400"]
EOF
```

```text
Error from server: error when creating "STDIN": admission webhook "vpol.validate.kyverno.svc-fail" denied the request: Policy require-image-exception failed: image requires an explicit exception
```

`pause:3.9` was exempted through `exceptions.allowedImages`; `busybox:1.29-4` was still evaluated and still failed. Same exception shape, same Pod, opposite outcome.

Cleanup:

```bash
kubectl delete ns demo-vp
kubectl -n kyverno-exceptions delete policyexception.policies.kyverno.io vp-allow-pause
kubectl delete validatingpolicy.policies.kyverno.io require-image-exception
```

## Expected behaviour

Either:

1. Register `exceptions` in the `ImageValidatingPolicy` CEL environment, so `exceptions.allowedImages` works as it does in `ValidatingPolicy`. `images.containers` is already a list of image-reference strings, so `i in exceptions.allowedImages` should need no new type work; or
2. Until then, reject `PolicyException.spec.images` (and `spec.allowedValues`) at apply time when `policyRefs` names an `ImageValidatingPolicy`.

Silently accepting an image-scoped exception and applying it to the whole resource broadens an approved exception without the operator seeing it. An error at `kubectl apply` costs nothing; silent acceptance costs a bypass that leaves no trace — under `validationActions: [Audit]` the mixed Pod produces a single `skip` row and no result at all for the unverified image.

## Related

- [#13817](https://github.com/kyverno/kyverno/issues/13817) — where `spec.images` / `exceptions.allowedImages` shipped, for `ValidatingPolicy`.
- [KDP#77](https://github.com/kyverno/KDP/pull/77) — the fine-grained exceptions design. Enumerates `ValidatingPolicy`, `MutatingPolicy`, `GeneratingPolicy`; `ImageValidatingPolicy` is absent.
- [#8663](https://github.com/kyverno/kyverno/issues/8663) — the same request against the legacy `verifyImages` path, closed stale.
- [#9478](https://github.com/kyverno/kyverno/issues/9478) — *Policy Exceptions 3.0*, which still carries it unchecked.
