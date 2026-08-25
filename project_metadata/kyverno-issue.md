# Upstream issue — ready to post

Post to <https://github.com/kyverno/kyverno/issues/new/choose> → **Bug Report**.
Everything below the line is the issue body.

Before posting: re-check the linked issue states (this was written 2026-08-25), and replace
`<registry>` with any registry you like — the behaviour does not depend on it.

The long-form version, with the full archaeology of how the gap arose and a 25-row index of
every related issue and KDP, is in
[`history/poc/kyverno-issue-draft.md`](history/poc/kyverno-issue-draft.md). It is the working
notes behind this; do not post both.

---

**Title:**

```
[Bug] PolicyException is resource-scoped for ImageValidatingPolicy: exempting one image in a pod skips verification for all of them, and spec.images is silently ignored
```

**Labels:** `bug`, `imageVerify`, `policy-exception`

---

## Software version numbers

| | |
|---|---|
| Kubernetes | v1.33 (EKS) |
| Kyverno | v1.18.2 |
| Chart | 3.8.2 |

## Description

`ValidatingPolicy` and `ImageValidatingPolicy` behave differently in a way that is not
documented, and the difference goes the wrong way for image verification:

|  | `ValidatingPolicy` | `ImageValidatingPolicy` |
|---|---|---|
| unit of judgement | the resource | **each image** |
| `PolicyException` with `spec.images` | scopes the exemption to those images; the policy still runs and reads them back as `exceptions.allowedImages` | **accepted and ignored** |
| a matching `PolicyException` | the policy still evaluates the other images | **skips the whole policy for the resource** |

So on the policy type whose whole purpose is per-image verification, exempting one image in a
pod stops verification of every other image in that pod. On the policy type where per-resource
scoping would be the natural fit, per-image scoping works.

This is not a missing feature at the CRD level — `spec.images` and `spec.allowedValues` are on
the `PolicyException` CRD, are accepted by the API server, and read back intact. They just do
nothing here, because the `exceptions` CEL variable is not registered in the ivpol environment.
Silent acceptance is the part that causes harm.

## Steps to reproduce

Two containers, one legitimately exempt and one not.

**1. A policy requiring every image to be signed.**

```yaml
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
            -----BEGIN CERTIFICATE-----
            <your CA>
            -----END CERTIFICATE-----
  validations:
    - expression: >-
        images.containers.all(image, verifyImageSignatures(image, [attestors.notary]) > 0)
      message: image is not signed
```

**2. An exception for ONE image, scoped with `spec.images`.**

```yaml
apiVersion: policies.kyverno.io/v1
kind: PolicyException
metadata:
  name: allow-approved
  namespace: kyverno-exceptions
spec:
  policyRefs:
    - name: require-signed
      kind: ImageValidatingPolicy
  images:
    - <registry>/approved:1.0          # <-- the only image this should cover
  matchConditions:
    - name: has-approved
      expression: object.spec.containers.exists(c, c.image == '<registry>/approved:1.0')
```

**3. A pod with the approved image and a different unsigned one.**

```bash
kubectl -n demo apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: mixed}
spec:
  containers:
    - {name: approved, image: <registry>/approved:1.0}
    - {name: other,    image: <registry>/unsigned:1.0}   # covered by nothing
EOF
```

**Expected:** denied. `unsigned:1.0` is not signed and no exception names it.

**Actual:** admitted. The exception matched the resource, so the whole policy was skipped and
`unsigned:1.0` was never verified. `spec.images` had no effect.

Under `validationActions: [Audit]` the same thing shows up as a single `skip` row for the pod
naming the exception — `unsigned:1.0` produces no result at all.

### The CEL half, if you want a one-step version

Referencing `exceptions` in an ivpol fails at policy-creation time:

```
spec.validations[0].expression: Invalid value:
  "images.containers.all(i, i in exceptions.allowedImages || verifyImageSignatures(i, [attestors.notary]) > 0)":
  ERROR: <input>:1:31: undeclared reference to 'exceptions' (in container '')
```

The identical expression on a `ValidatingPolicy` compiles.

## Expected behaviour

Either would resolve this; the first is the feature, the second is the safety net.

1. **Register `exceptions` in the `ImageValidatingPolicy` CEL environment**, so
   `exceptions.allowedImages` works as it does in `ValidatingPolicy`. `images.containers` is
   already a list of plain image-reference strings, so `i in exceptions.allowedImages` needs no
   new type work.

2. **Until then, reject the combination rather than ignoring it.** A `PolicyException` carrying
   `spec.images` or `spec.allowedValues` whose `policyRefs` name an `ImageValidatingPolicy`
   should be refused by the exception's own validating webhook, saying fine-grained exceptions
   are not supported for that policy type on this version. An error at `kubectl apply` costs the
   operator nothing; silent acceptance costs them a bypass they cannot see.

A note in the [ImageValidatingPolicy docs](https://kyverno.io/docs/policy-types/image-validating-policy/)
would help either way — they link to `PolicyException` without mentioning that the fine-grained
fields do not apply.

## Related

- [#13817](https://github.com/kyverno/kyverno/issues/13817) — where `spec.images` /
  `exceptions.allowedImages` shipped, for `ValidatingPolicy`.
- [KDP#77](https://github.com/kyverno/KDP/pull/77) — the fine-grained exceptions design.
  Enumerates `ValidatingPolicy`, `MutatingPolicy`, `GeneratingPolicy`; `ImageValidatingPolicy`
  is absent.
- [#8663](https://github.com/kyverno/kyverno/issues/8663) — the same request against the legacy
  `verifyImages` path, closed stale. Tracked under
  [#9478](https://github.com/kyverno/kyverno/issues/9478) (*Policy Exceptions 3.0*), which still
  carries it unchecked.

## Additional context

Found while building an admission model where a pod may legitimately mix a signed first-party
image, an approved-unsigned first-party image, and an approved vendor image, and where an
exemption for one must not weaken verification of the others.

The workaround is to move the exemption list into `matchImageReferences[].expression` on the
policy itself, which works and even avoids fetching an out-of-scope image at all. But it puts
the exemption list inside the policy object, so exemptions can no longer be reviewed, RBAC'd,
expired or audited independently of the policy — which is the entire reason `PolicyException`
exists.

Happy to open a KDP alongside KDP#77 if that is the preferred route.
