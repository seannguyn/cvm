# Upstream issue draft

Post to <https://github.com/kyverno/kyverno/issues/new/choose> → **Bug Report**.

Everything below the line is the issue body. Replace the two `<…>` placeholders with your own
values (or leave the registry redacted — the behaviour does not depend on it).

## Every referenced issue, clickable

Reference index for reading this file — **not part of the issue body**, which starts below
the line and carries its own inline links.

| ref | title | state | why it is here |
|---|---|---|---|
| [KDP#33](https://github.com/kyverno/KDP/pull/33) | Policy exceptions | merged 2022-09 | The original design. Exceptions are **resource**-scoped; there was never a sub-resource unit. |
| [#5662](https://github.com/kyverno/kyverno/issues/5662) | feat: Introduce PolicyException CRD | merged 2022-12 | The CRD. |
| [#5680](https://github.com/kyverno/kyverno/issues/5680) | feat: Implement PolicyException | merged 2022-12 | The implementation, shipped 1.9. |
| [KDP#49](https://github.com/kyverno/KDP/pull/49) | Apply policy exceptions after executing the policy | merged 2023-09 | Cements the semantics: a match discards the rule's outcome for the whole resource. |
| [#8663](https://github.com/kyverno/kyverno/issues/8663) | [Feature] Support `imageReferences` in Policy Exceptions for verify image rules | **closed — stale** | **The exact request.** Filed as a feature, so the defect was never triaged as one. |
| [#8570](https://github.com/kyverno/kyverno/issues/8570) | Allow specifying a container within a Pod in Policy Exceptions | **closed — not planned** | Same shape one level up: exempt the sidecar, keep the app container restricted. |
| [#9478](https://github.com/kyverno/kyverno/issues/9478) | [Tracking] Policy Exceptions 3.0 | **OPEN** | Still carries #8663 unchecked since Jan 2024. Where option 1 belongs. |
| [#9789](https://github.com/kyverno/kyverno/issues/9789) | Support for excluding images for policy exception | closed unmerged | Draft PR, legacy path. |
| [#11371](https://github.com/kyverno/kyverno/issues/11371) | Implement skip image ref | closed unmerged | A working implementation for legacy `verifyImages`, milestone 1.15. |
| [KDP#70](https://github.com/kyverno/KDP/pull/70) | Image validating policy CRD | merged 2025-05 | **Never mentions PolicyException.** ivpol was designed with no exception story. |
| [#13654](https://github.com/kyverno/kyverno/issues/13654) | CEL based fine-grained Exceptions | epic | The umbrella for the feature that shipped. |
| [#13662](https://github.com/kyverno/kyverno/issues/13662) | Implement fine-grained policy exceptions | closed unmerged | **The pivot.** Closed in favour of putting this in the *new* policy types. |
| [KDP#77](https://github.com/kyverno/KDP/pull/77) | Fine-grained exceptions design proposal | **OPEN** | Enumerates vpol / mpol / gpol. **ivpol is absent.** |
| [#13817](https://github.com/kyverno/kyverno/issues/13817) | feat: fine-grained cel exceptions | **merged** | `spec.images` / `.allowedValues` + the `exceptions` CEL variable. |
| [#13922](https://github.com/kyverno/kyverno/issues/13922) | feat: generate VAPs from fine-grained exceptions | merged | Follow-on. |
| [#15234](https://github.com/kyverno/kyverno/issues/15234) | fine-grained CEL exceptions for MutatingPolicy | **OPEN** | mpol being brought in deliberately. Nothing equivalent for ivpol. |
| [#15678](https://github.com/kyverno/kyverno/issues/15678) | test: fine grained exceptions for mpol | merged | e2e coverage for the above. |
| [#16053](https://github.com/kyverno/kyverno/issues/16053) | [Bug] ValidatingPolicy ignores full-exemption PolicyException | fixed 2026-07 | Proof the `spec.images` path is live and exercised — on **vpol**. |
| [#16060](https://github.com/kyverno/kyverno/issues/16060) | fix: honor full-exemption PolicyException | merged 2026-07 | The fix for the above. |
| [#16299](https://github.com/kyverno/kyverno/issues/16299) | feat: honor expired CEL PolicyExceptions | merged 2026-06 | Merged **after** v1.18.2 — why `spec.expiresAt` is also declared-but-inert here. |
| [#16678](https://github.com/kyverno/kyverno/issues/16678) | [Bug] ivpol attestation verification; PolicyException cannot except | **OPEN** | Different trigger, same area of ivpol exception handling. |
| [#16730](https://github.com/kyverno/kyverno/issues/16730) | test(integration): ImageValidatingPolicy framework | merged | Where a regression test for this would go. |
| [#16815](https://github.com/kyverno/kyverno/issues/16815) | fix: IVPOL mutateDigest unimplemented stub | merged | **A third** ivpol field the API accepted and the engine ignored. |
| [#16993](https://github.com/kyverno/kyverno/issues/16993) | fix(cel): read PolicyExceptions from the manager cache | **OPEN** | Exceptions silently ignored on some HA replicas. |
| [#17106](https://github.com/kyverno/kyverno/issues/17106) | [Bug] Policy Exceptions not effective immediately | **OPEN** | Up to 5+ minutes before an exception applies. |
| [#17139](https://github.com/kyverno/kyverno/issues/17139) | [Bug] PolicyException matching performs uncached Namespace GET | **OPEN** | ~11.5 namespace fetches per pod admission when any exception names the policy. |

Also linked in the body: the [ImageValidatingPolicy docs](https://kyverno.io/docs/policy-types/image-validating-policy/), the [1.16 release notes](https://kyverno.io/blog/2025/11/10/announcing-kyverno-release-1.16/), and [new issue](https://github.com/kyverno/kyverno/issues/new/choose).

---

**Title:**

```
[Bug] PolicyException spec.images and spec.allowedValues are accepted but inert for ImageValidatingPolicy: `exceptions` is not registered in the ivpol CEL environment
```

**Labels to request:** `bug`, `imageVerify`, `policy-exception`

---

## Software version numbers

| | |
|---|---|
| Kubernetes | v1.33 (EKS) |
| Kyverno | **v1.18.2** |
| Helm chart | **3.8.2** |
| Policy type | `policies.kyverno.io/v1` `ImageValidatingPolicy` |
| Exception type | `policies.kyverno.io` `PolicyException` |

## Description

`PolicyException` on 1.18.2 declares the full fine-grained exception API — `images`,
`allowedValues`, `expiresAt`, `properties`, `reportResult`, `evaluationMode`:

```console
$ kubectl get crd policyexceptions.policies.kyverno.io -o json \
  | jq -r '.spec.versions[-1].schema.openAPIV3Schema.properties.spec.properties | keys | join(", ")'
allowedValues, evaluationMode, expiresAt, images, matchConditions, policyRefs, properties, reportResult
```

The mechanism that consumes `spec.images` is the `exceptions` CEL variable
(`exceptions.allowedImages`), introduced for `ValidatingPolicy` in 1.16 via [#13654](https://github.com/kyverno/kyverno/issues/13654) / [KDP#77](https://github.com/kyverno/KDP/pull/77).

**That variable is not registered in the `ImageValidatingPolicy` CEL environment.** Any policy that
references it is rejected at admission:

```console
$ kubectl apply --dry-run=server -f ivpol.yaml
admission webhook "validate-policy.kyverno.svc" denied the request:
spec.validations[0].expression: Invalid value:
"images.containers.all(i, i in exceptions.allowedImages || verifyImageSignatures(i, [attestors.notary]) > 0)":
ERROR: <input>:1:31: undeclared reference to 'exceptions' (in container '')
 | images.containers.all(i, i in exceptions.allowedImages || verifyImageSignatures(i, [attestors.notary]) > 0)
 | ..............................^
```

So on an `ImageValidatingPolicy`, `spec.images` on a `PolicyException` has no path to affect
evaluation. The API server accepts it, the field is stored, `kubectl get -o yaml` shows it back, no
warning is emitted anywhere — and the exception continues to exempt the **entire resource**, which
is what it did before the field was set.

### Why this is a bug and not a missing feature

It **fails open, silently**. An operator writes an exception intending to scope it to one image:

```yaml
apiVersion: policies.kyverno.io/v1
kind: PolicyException
metadata:
  name: allow-legacy-sidecar
  namespace: kyverno-exceptions
spec:
  policyRefs:
    - name: require-signed-images
      kind: ImageValidatingPolicy
  images:
    - "<registry>/team/legacy-sidecar:1.4"     # intended: this image only
  matchConditions:
    - name: has-legacy-sidecar
      expression: object.spec.containers.exists(c, c.image == '<registry>/team/legacy-sidecar:1.4')
```

Every signal available to them says this worked: `kubectl apply` succeeds, a round-trip read shows
`spec.images` intact, `kubeconform -strict` passes, and the intended pod is admitted. What they
actually created exempts **every image in every matching pod** from signature verification —
including images they have never seen. A field that narrows the blast radius in a reviewer's mental
model while doing nothing in the engine is worse than one that does not exist, because the reviewer
stops looking.

For a signature-verification policy, "exempts the whole pod" means one approved unsigned sidecar
silently also permits an unsigned, unreviewed application image next to it.

## Steps to reproduce

Minimal repro, no registry credentials needed — step 1 alone demonstrates the missing registration.

**1. `exceptions` is unresolvable in an ivpol expression.**

```bash
cat <<'EOF' | kubectl apply --dry-run=server -f -
apiVersion: policies.kyverno.io/v1
kind: ImageValidatingPolicy
metadata:
  name: repro-exceptions-unbound
spec:
  validationActions: [Audit]
  evaluation:
    admission: {enabled: true}
    background: {enabled: false}
  matchConstraints:
    resourceRules:
      - apiGroups: [""]
        apiVersions: ["v1"]
        operations: ["CREATE"]
        resources: ["pods"]
  matchImageReferences:
    - glob: "*"
  attestors:
    - name: notary
      notary:
        certs:
          value: |
            -----BEGIN CERTIFICATE-----
            <any valid PEM>
            -----END CERTIFICATE-----
  validations:
    - expression: >-
        size(exceptions.allowedImages) >= 0 &&
        images.containers.all(i, verifyImageSignatures(i, [attestors.notary]) > 0)
      message: repro
EOF
```

Actual: `ERROR: <input>:1:6: undeclared reference to 'exceptions' (in container '')`.
The identical expression on a `ValidatingPolicy` compiles.

**2. `spec.images` does not narrow an exception (needs a real signing setup).**

Given an enforcing `ImageValidatingPolicy` that requires a Notary signature, and an unsigned image
`app:3.0` that a `PolicyException` legitimately exempts:

```bash
# Scope the exception to app:3.0 only.
kubectl -n kyverno-exceptions patch policyexception allow-app-30 --type=merge \
  -p '{"spec":{"images":["<registry>/soe-demo/app:3.0"]}}'

# Now deploy a DIFFERENT unsigned image that the exception was never meant to cover.
kubectl -n demo run sneaky --image=<registry>/soe-demo/app:1.0 --restart=Never
```

**Expected:** `sneaky` is **denied** — `app:1.0` is not in `spec.images`.
**Actual:** `sneaky` is **admitted**. The exception still applies to the whole resource; `spec.images`
had no effect.

## Expected behaviour

Either of these would resolve it; the first is the feature, the second is the safety net.

1. **Register `exceptions` in the `ImageValidatingPolicy` CEL environment**, so
   `exceptions.allowedImages` is usable exactly as it is in `ValidatingPolicy`. Given that
   `images.containers` is already a list of plain image-reference strings on this version,
   `i in exceptions.allowedImages` is the natural spelling and needs no new type work.

2. **Until then, reject the combination instead of ignoring it.** A `PolicyException` carrying
   `spec.images` or `spec.allowedValues` whose `policyRefs` include `kind: ImageValidatingPolicy`
   should be refused by the exception's own validating webhook, with a message saying fine-grained
   exceptions are not supported for that policy type on this version. Silent acceptance is the part
   that causes harm; an error at `kubectl apply` costs the operator nothing.

A note in the [ImageValidatingPolicy docs](https://kyverno.io/docs/policy-types/image-validating-policy/)
would help either way — it currently links to `PolicyException` without noting that the
fine-grained fields do not apply.

If option 1 is on the roadmap, **[#9478](https://github.com/kyverno/kyverno/issues/9478) (*Policy Exceptions 3.0*)** is where it belongs: that
tracking issue has carried [#8663](https://github.com/kyverno/kyverno/issues/8663) (*"Support imageReferences in Policy Exceptions for verify image
rules"*) unchecked since January 2024, and this is the same requirement expressed against the policy
type that replaced `verifyImages`. Happy to open a KDP alongside [KDP#77](https://github.com/kyverno/KDP/pull/77) if that is the preferred
route.

## Slack discussion

_None._

## Troubleshooting

- [x] I have read and followed the documentation AND troubleshooting guide.
- [x] I have searched other issues and found no duplicate.

## Related work, and the history behind it

Everything below is upstream. It is included because the short version — *"ivpol was left out"* —
is only convincing with the sequence attached, and because the sequence shows this is an omission
rather than a decision anyone recorded.

### 1. Exceptions were resource-scoped by design, from the first day

- **[KDP#33](https://github.com/kyverno/KDP/pull/33) — *Policy exceptions*** (2022-09-16, merged). The original design. An exception
  identifies a **resource** and the rules it is exempt from; there was never a sub-resource unit.
- **[#5662](https://github.com/kyverno/kyverno/issues/5662) / [#5680](https://github.com/kyverno/kyverno/issues/5680)** (2022-12, merged, shipped in 1.9). The CRD and its implementation.
- **[KDP#49](https://github.com/kyverno/KDP/pull/49) — *Apply policy exceptions after executing the policy itself*** (2023-09-28, merged).
  Cements the semantics this issue is about: a matched exception discards the rule's outcome for
  the whole resource. Correct for `validate`. For `verifyImages`, where the unit of judgement is
  an image and a pod carries several, it is the source of every request below.

### 2. Per-image / per-container exceptions: asked for four times, delivered zero times

- **[#8663](https://github.com/kyverno/kyverno/issues/8663) — *[Feature] Support `imageReferences` in Policy Exceptions for verify image rules***
  (2023-10-16). **Closed as stale.** The exact request, filed as a feature so the underlying
  defect was never triaged as one.
- **[#8570](https://github.com/kyverno/kyverno/issues/8570) — *Allow specifying a container within a Pod in Policy Exceptions*** (2023-11).
  **Closed as not planned.** Same shape, one level up: exempt the sidecar, keep the app
  container restricted.
- **[#9789](https://github.com/kyverno/kyverno/issues/9789) — *Support for excluding images for policy exception*** (2024-02-25). Draft PR.
  **Closed unmerged.**
- **[#11371](https://github.com/kyverno/kyverno/issues/11371) — *Implement skip image ref*** (2024-10-09). A working implementation for legacy
  `verifyImages`, milestone 1.15.0. **Closed unmerged.**
- **[#13662](https://github.com/kyverno/kyverno/issues/13662) — *Implement fine-grained policy exceptions*** (2025-07-23). `images`, `values` and
  `reportAs` on `PolicyException`. **Closed unmerged**, and the closing rationale is the pivot
  point for this issue: maintainers chose to put fine-grained exceptions into the **new** policy
  types rather than extend `ClusterPolicy`.

**[#9478](https://github.com/kyverno/kyverno/issues/9478) — *[Tracking] Policy Exceptions 3.0*** (2024-01-22) is **still open** and still carries
[#8663](https://github.com/kyverno/kyverno/issues/8663) — *"Support imageReferences in Policy Exceptions for verify image rules"* — **unchecked**,
more than two years on. Also unchecked: *"support exceptions on a foreach list element"* — the same
problem for a different iteration unit.

### 3. Fine-grained exceptions shipped — for the other new policy types

- **[#13654](https://github.com/kyverno/kyverno/issues/13654) — *CEL based fine-grained Exceptions*** (2025-07-22). The epic.
- **[KDP#77](https://github.com/kyverno/KDP/pull/77) — *fine-grained exceptions design proposal*** (2025-07-30). **Still open.**
- **[#13817](https://github.com/kyverno/kyverno/issues/13817) — *feat: fine-grained cel exceptions*** (2025-08-11, **merged**). The foundation:
  `PolicyException.spec.images` / `.allowedValues`, surfaced to policies as the CEL variable
  `exceptions`.
- **[#13922](https://github.com/kyverno/kyverno/issues/13922) — *feat: generate VAPs from fine-grained exceptions*** (2025-08-29, merged).
- **Kyverno 1.16** (2025-11-10) announces it. Every documented example is a `ValidatingPolicy`.
- **[#15234](https://github.com/kyverno/kyverno/issues/15234) — *feat: add fine-grained CEL exceptions (Images/AllowedValues) for MutatingPolicy***
  (2026-02-13, **open**), with **[#15678](https://github.com/kyverno/kyverno/issues/15678)** (merged) adding its e2e coverage. `MutatingPolicy` is
  being brought in deliberately and visibly. Nothing equivalent exists for
  `ImageValidatingPolicy`.

### 4. Why ivpol specifically fell through

**[KDP#70](https://github.com/kyverno/KDP/pull/70) — *Image validating policy CRD*** (2025-01-27, merged 2025-05-14) is the design this
policy type was built from. **It does not mention `PolicyException` anywhere** — not to support
it, not to defer it, not to rule it out. The exception story was simply not part of the design.

[KDP#77](https://github.com/kyverno/KDP/pull/77) then arrived five months later to add fine-grained exceptions to the new policy types, and
enumerated `ValidatingPolicy`, `MutatingPolicy` and `GeneratingPolicy`. `ImageValidatingPolicy` is
absent from both documents.

So the gap is not a considered trade-off recorded somewhere and later forgotten. It is the
intersection of two proposals that each assumed the other covered it — which is also why the CRD
carries the fields (they are shared) while the engine cannot read them (registration is
per-policy-type).

The irony worth stating plainly: **`ImageValidatingPolicy` is the policy type with the strongest
case for per-image exceptions** — it is the only one whose unit of judgement is an image rather
than the resource — and it is the only new type that did not get them.

### 5. Adjacent, and useful when triaging this

- **[#16053](https://github.com/kyverno/kyverno/issues/16053) / [#16060](https://github.com/kyverno/kyverno/issues/16060)** (reported against 1.18.0, fixed 2026-07-28) — `allowedImages` accumulate
  across matching exceptions and a full-exemption exception is silently overridden by an
  image-scoped one. Proof the `spec.images` path is live and exercised on `ValidatingPolicy`.
- **[#16678](https://github.com/kyverno/kyverno/issues/16678)** (open) — `ImageValidatingPolicy`: a matching `PolicyException` *"does NOT except
  under Deny"* for cosign v3 attestations. Different trigger, same area.
- **[#16993](https://github.com/kyverno/kyverno/issues/16993)** (open) — `PolicyException`s for CEL policies silently ignored on some HA replicas.
- **[#17106](https://github.com/kyverno/kyverno/issues/17106)** (open) — up to 5+ minutes before an exception takes effect.
- **[#17139](https://github.com/kyverno/kyverno/issues/17139)** (open) — an uncached namespace GET per rule per admission whenever any exception
  names the policy.
- **[#16299](https://github.com/kyverno/kyverno/issues/16299)** (merged 2026-06-26, i.e. after v1.18.2) — *honor expired CEL PolicyExceptions*.
  The reason `spec.expiresAt` is in the same "declared, accepted, inert" state on this version.
- **[#16815](https://github.com/kyverno/kyverno/issues/16815)** (merged) — `mutateDigest` was an unimplemented stub on ivpol. A third field on this
  policy type that the API accepted and the engine ignored, which is why the pattern is worth
  naming rather than fixing case by case.
- **[#16730](https://github.com/kyverno/kyverno/issues/16730)** (merged) — the ivpol integration-test framework, including PolicyException skip
  behaviour. The natural place for a regression test if this is fixed.

### 6. Where the legacy path ended up, for completeness

`ClusterPolicy` `verifyImages` never got per-image exceptions either ([#9789](https://github.com/kyverno/kyverno/issues/9789), [#11371](https://github.com/kyverno/kyverno/issues/11371), [#13662](https://github.com/kyverno/kyverno/issues/13662) all
closed unmerged), and after [#13662](https://github.com/kyverno/kyverno/issues/13662) it will not: the decision was to invest in the new types.
Anyone on the legacy path today has the same problem with no roadmap, and anyone migrating to
`ImageValidatingPolicy` to get one arrives at this issue.

## Additional context

Found while building an admission model where a pod may legitimately mix a signed first-party image,
an approved-unsigned first-party image, and an approved vendor image, and where an exemption for one
image must not weaken verification of the others. Because `PolicyException` is resource-scoped for
`ImageValidatingPolicy`, the working solution is to move the exemption list into
`matchImageReferences[].expression` on the policy itself:

```
ref.startsWith('<registry>/soe-demo/') && !(ref in ['<exempt-1>', '<exempt-2>'])
```

That works, and has one incidental advantage — an image excluded by scope is never fetched, whereas
an image excluded by `exceptions.allowedImages` must be matched first. But it puts the exemption
list inside the policy object, so exemptions can no longer be reviewed, RBAC'd, expired, or audited
independently of the policy, which is the entire reason `PolicyException` exists.

Two smaller observations from the same investigation, mentioned only in case they are useful — happy
to split either into its own issue:

- `spec.expiresAt` is likewise declared and accepted on 1.18.2 but appears not to be enforced
  (consistent with [#16299](https://github.com/kyverno/kyverno/issues/16299) merging after the release). Same failure mode: the field reads back
  intact and does nothing.
- The [ImageValidatingPolicy docs](https://kyverno.io/docs/policy-types/image-validating-policy/)
  show `image.registry` / `image.registry()` styles, but in `matchImageReferences[].expression` on
  1.18.2 the only binding that resolves is a bare string named `ref` — `image` is undeclared.

---

### The history in one paragraph, for triage

Exceptions have been resource-scoped since [KDP#33](https://github.com/kyverno/KDP/pull/33) (2022), which is correct for `validate` and wrong
for image verification, where the unit of judgement is an image and a pod carries several. That gap
was raised four times against the legacy path ([#8663](https://github.com/kyverno/kyverno/issues/8663), [#8570](https://github.com/kyverno/kyverno/issues/8570), [#9789](https://github.com/kyverno/kyverno/issues/9789), [#11371](https://github.com/kyverno/kyverno/issues/11371)) and closed four times —
stale, not planned, unmerged, unmerged. [#13662](https://github.com/kyverno/kyverno/issues/13662) then redirected the work to the new policy types,
where it shipped in 1.16 as `spec.images` + `exceptions.allowedImages`. But
`ImageValidatingPolicy`'s own design ([KDP#70](https://github.com/kyverno/KDP/pull/70)) never mentioned exceptions, and the fine-grained
design ([KDP#77](https://github.com/kyverno/KDP/pull/77)) enumerated `ValidatingPolicy`, `MutatingPolicy` and `GeneratingPolicy` and not
ivpol. The shared CRD therefore carries the fields while the ivpol engine cannot read them, and the
result is not an error but silence.
