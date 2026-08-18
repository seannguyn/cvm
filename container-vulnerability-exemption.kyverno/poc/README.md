# Kyverno `ImageValidatingPolicy` — end-to-end test plan

**Status:** test material · **Date:** 2026-08-17 · **Relates to:** [ADR-0002](../../README.md#adr-0002--wiz-as-the-admission-and-exemption-control-plane) (Option A)

This directory exists because the root ADR chose Wiz and kept `kyverno/` empty for the day a
revisit trigger fires. This is not that implementation — it is the **evidence-gathering
exercise** that would have to precede it. The point is to find out, on our own EKS clusters
and with our own Notation PKI, whether `ImageValidatingPolicy` does what Option A assumed it
did.

Everything here is Notary/Notation (ADR-0001). Cosign paths are noted only where the two
differ in a way that changes a conclusion.

---

## 0. Read this before you start — five findings that change the test

These came out of reading the Kyverno source (`v1.18.2`, the current stable, and `main` at
`1df9235`, which is `v1.19.0-rc.3`). Each one either contradicts something in the root ADR or
is a trap you will otherwise fall into. They are what the tests in §5 and §7 are built around.

### F1. Kyverno does **not** support Notary signer-identity pinning either

`ADR-0003 → Consequences` says DN discipline "is a prerequisite for both revisit paths — Wiz
adding pinning, or a move to Kyverno, **which supports it today**." That is **false**.

Kyverno builds the Notation trust policy in Go and hardcodes it
(`pkg/image/verifiers/ivpol/notary/helpers.go`, and identically for legacy `verifyImages` in
`pkg/image/verifiers/cpol/notary/notary.go`):

```go
trustpolicy.TrustPolicy{
    Name:                  "kyverno",
    RegistryScopes:        []string{"*"},
    SignatureVerification: trustpolicy.SignatureVerification{VerificationLevel: trustpolicy.LevelStrict.Name},
    TrustStores:           truststores,
    TrustedIdentities:     []string{"*"},
}
```

`TrustedIdentities: ["*"]` — there is no field on the `notary` attestor to change it. The CRD
exposes exactly two knobs, `certs` and `tsaCerts`, and nothing else. So under Kyverno, as
under Wiz, **the trust store is the only authorization boundary**, and ADR-0003's standalone
signing root remains necessary. This removes one of the two revisit paths ADR-0003 was
counting on, and it should be corrected in the root README regardless of what this test
concludes.

What Kyverno *does* give you that Wiz does not is scoping on the **consumer** side rather than
the signer side: `matchImageReferences` (glob or CEL over the image ref), `matchConstraints`
(GVR/operations), `matchConditions` (CEL over the whole admission request), and namespaced
policy variants. That is a real difference and §5.6 tests it — but it is not identity pinning,
and it does not stop a holder of any cert under the trusted root from signing an image that
lands in scope.

### F2. `TrustedIdentities: ["*"]` is not the only thing `LevelStrict` decides — revocation is **enforced**

`LevelStrict` sets `TypeRevocation: ActionEnforce` (notation-go v1.3.2,
`verifier/trustpolicy/trustpolicy.go`). Kyverno gives you no way to lower this to
`permissive`.

Our leaf certs today carry `basicConstraints=critical,CA:FALSE`,
`keyUsage=critical,digitalSignature`, `extendedKeyUsage=codeSigning` and **no AIA/CDP
extensions** (`container-vulnerability-exemption/image-signing/gen_signing_certs.sh`). notation-core-go scores a cert with no
OCSP and no CRL endpoint as `ResultNonRevokable`, which `revocationFinalResult` counts as OK —
so verification passes without egress. Good.

But this is a **latent egress dependency**: the day the PKI team starts stamping CRL
distribution points or an OCSP responder URL onto leaves (a normal thing for an approved
internal CA to want), Kyverno's admission path acquires a hard dependency on reaching that
endpoint from inside every cluster, through the proxy allowlist, on the critical path to
creating a pod. Test 5.7 exercises this deliberately.

`LevelStrict` also enforces `TypeAuthenticTimestamp` and `TypeExpiry`, which is consistent
with ADR-0001's deliberate no-trust-timestamping choice: an expired leaf stops admitting.

### F3. `validationConfigurations.required` is **inert on v1.18.2**

The field exists in the CRD on 1.18.2 and accepts `true`. Nothing reads it — grep the whole
`pkg/` tree of `v1.18.2` for `validationConfig.Required` and you get nothing. The catch-all
enforcement (`EnforceRequired`, "image X is not verified: no policy performed a signature or
attestation check on it") **only lands in `main`/v1.19**.

Consequence for 1.18.2: an image that no policy's `matchImageReferences` selects is admitted
silently. Fail-closed is not a checkbox; you have to build it out of a catch-all policy whose
`matchImageReferences` is `**` and whose validation expression fails. Test 5.5.

### F4. On v1.18.2 the verification outcome is passed between webhooks in a **pod annotation**

This is the single most important thing to know about 1.18.x.

- The **mutating** webhook (`ivpol.mutate.kyverno.svc`, path `/ivpol/mutate`) does the actual
  registry fetch and signature verification, then patches the result into
  `kyverno.io/image-verification-outcomes` on the pod.
- The **validating** webhook (`ivpol.validate.kyverno.svc`) reads that annotation. If the
  annotation is missing it errors with `annotations not present on object, image verification
  failed`.

`main` deleted this, with a commit comment that says the quiet part out loud:

> Image verification ... is performed exclusively by `HandleValidating`. Running it here too
> would duplicate registry/attestor calls, and previously relied on an annotation to hand the
> outcome off to the validating webhook — an outcome that a caller could forge and that would
> be trusted if the mutating webhook was ever [bypassed].

In the normal path the mutating webhook overwrites whatever the user supplied, so forgery
fails. The risk is any path where the **mutating webhook does not run but the validating
webhook does**: a `namespaceSelector`/`objectSelector` that differs between the two
configurations, `failurePolicy: Ignore` on the mutating webhook during a Kyverno outage, or
someone editing one webhook config and not the other. Test 5.8 tries to forge it. If you are
going to run IVP in enforcement on 1.18.x, you need an answer to this.

On 1.18.2 the mutating webhook is registered for **every** IVP regardless of `mutateDigest`.
On `main` it is registered only for policies that actually need digest mutation, which is what
makes `mutateDigest: false` a meaningful latency optimisation (§7, P2b).

### F5. `PolicyException` gets native expiry in v1.19, not v1.18

ADR-0002 rationale 3 says expiry is a first-class field in Wiz and "composed" in Kyverno. True
on v1.18.2 — `policies.kyverno.io/v1beta1 PolicyException` there has only `allowedValues`,
`images`, `matchConditions`, `policyRefs`, `reportResult`.

On v1.19 it gains **`expiresAt`** (RFC3339), **`properties`** (a free-form map the CRD
documents for exactly `reason` / `ticket` / `approved-by`), and `evaluationMode`. Expiry is
enforced in `pkg/cel/engine/exception.go`:

```go
for _, exception := range exceptions {
    if exception.IsExpired() { continue }
    ...
}
```

That is rationale 3 gone, and rationale 1 partially dented (`properties` gives you the ticket
and approver on the exemption object itself). Rationale 2 — fan-out to ~200 etcds vs one
tenant API — stands untouched and is still the strongest argument for Wiz. Test 6.3 and 6.4
cover both versions.

One caveat worth measuring: expiry is applied when exceptions are *listed* during
reconciliation, not by a timer. An exception that expires does not take effect until the next
reconcile of the policy. Test 6.4 measures that lag.

---

## 1. Version decision

| | v1.18.2 (current stable) | v1.19.0-rc.x / `main` |
|---|---|---|
| IVP maturity | "Stable", `policies.kyverno.io/v1` served | same |
| Storage version | `v1beta1` | `v1beta1` |
| `required` catch-all | **inert** (F3) | enforced |
| Verification location | mutating webhook, via annotation (F4) | validating webhook only |
| Mutating webhook registered | always | only when `mutateDigest` |
| `PolicyException.expiresAt` | absent (F5) | present |
| Notary identity pinning | none (F1) | none |

**Recommendation:** run the functional suite (§5, §6) on **whatever version is already on the
cluster**, because that is the honest answer to "does this work here". Then re-run §5.5, §5.8,
§6.3 on **v1.19.0-rc** in a scratch cluster, because three of the five findings above turn on
that boundary and a decision made on 1.18.2 semantics would be a decision about software we
would not deploy.

Everything in `20-policies/` is written against `policies.kyverno.io/v1` and works on both.

---

## 2. Prerequisites

### 2.1 Verify the existing install

```bash
bash 00-prereqs/check-kyverno.sh
```

The script is the authority; this is what it checks and why each one matters.

| Check | Why |
|---|---|
| `kyverno` deployments present and Ready — `admission-controller`, `background-controller`, `cleanup-controller`, `reports-controller` | IVP admission needs the admission controller. Background scan and `PolicyReport` need the reports controller. A fleet that installed Kyverno "for config policy" may have trimmed the others. |
| Kyverno version from the container image tag | Decides F3/F4/F5 (§1). |
| CRDs `imagevalidatingpolicies.policies.kyverno.io` and `policyexceptions.policies.kyverno.io` exist, and which versions are `served`/`storage` | `crds.groups.policies.*` are Helm-gated. An older chart or a trimmed install will not have them, and `kubectl apply` fails with `no matches for kind`. |
| Admission controller flags: `--enablePolicyException`, `--exceptionNamespace`, `--imageVerifyCacheEnabled`, `--imageVerifyCacheTTLDuration`, `--imageVerifyCacheMaxSize`, `--registryCredentialHelpers`, `--allowInsecureRegistry` | §2.2. |
| `ValidatingWebhookConfiguration` / `MutatingWebhookConfiguration` — is `ivpol.validate.kyverno.svc` / `ivpol.mutate.kyverno.svc` present, with what `failurePolicy`, `timeoutSeconds`, `namespaceSelector`, `objectSelector` | Webhooks are created *on demand* when the first IVP is applied, by the webhook controller. Before that they do not exist — their absence is not a fault. After applying a policy, a mismatch between the mutate and validate selectors is exactly the F4 hole. |
| Existing non-Kyverno webhooks on `pods` — specifically the Wiz admission controller | Two fail-closed webhooks on the same verb is the risk ADR-0002 already accepted. §7 P12 measures the combined latency rather than assuming it adds up linearly. |
| Whether the admission controller can reach the registry (ECR IRSA / proxy) | §2.3. |
| `resourceFilters` in the `kyverno` ConfigMap | If the test namespace is inside an exclusion, nothing will fire and you will spend an hour on it. |

### 2.2 Feature flags to set

None of the IVP machinery is behind a feature gate, but four things need to be true:

```yaml
# 00-prereqs/values-ivpol.yaml — merge into the existing Helm values, do not replace them
crds:
  groups:
    policies:
      imagevalidatingpolicies: true
      namespacedimagevalidatingpolicies: true
      policyexceptions: true

features:
  policyExceptions:
    enabled: true            # OFF BY DEFAULT. Without it, PolicyException objects apply but are ignored.
    namespace: 'kyverno-exceptions'   # or '*' for any namespace. See 30-exceptions/README.md.
  registryClient:
    credentialHelpers: [default, amazon]   # ECR. 'default' alone will not do IRSA.
  backgroundScan:
    enabled: true
    backgroundScanInterval: 1h

admissionController:
  container:
    extraArgs:
      # NOT exposed as chart values — must go through extraArgs.
      imageVerifyCacheEnabled: true
      imageVerifyCacheTTLDuration: 60m
      imageVerifyCacheMaxSize: 1000
```

`features.policyExceptions.enabled` defaulting to `false` is the one that bites. The CRD is
installed, `kubectl apply` succeeds, `kubectl get polex` shows your object, and the exemption
does nothing.

The `imageVerifyCache*` flags are deliberately called out: they are **not** chart values in
either 1.18.2 or `main`, so they can only be set via `extraArgs`, and §7 needs to toggle them.

### 2.3 Registry access from inside the cluster

The admission controller — not the node, not your laptop — does the registry fetch. For a
Notary signature that is: resolve the manifest, call the **OCI referrers API** on the image
digest, pull the signature manifest, pull the signature blob. Four round trips per
cold-cache image, before any crypto.

- **ECR:** `credentialHelpers` must include `amazon`, and the Kyverno admission controller's
  ServiceAccount needs an IRSA role with `ecr:GetAuthorizationToken`,
  `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer` on the SOE repos. Confirm with
  `00-prereqs/check-registry-access.sh`.
- **Proxy allowlist:** the registry host must be reachable from the admission controller pod,
  through whatever `HTTPS_PROXY`/`NO_PROXY` the pod has. Note the reports controller needs the
  same access if `evaluation.background.enabled` is true — that is a second, easily-missed
  egress path.
- **Registry must support the referrers API** (OCI 1.1 `/v2/<name>/referrers/<digest>`) or the
  fallback tag schema. ECR does. Check with `scripts/check-referrers.sh`.

### 2.4 Local tooling

`notation` ≥ 1.2, `oras`, `jq`, `openssl`, `kubectl` ≥ 1.28, `aws` CLI. Optionally
`prometheus`/`kube-prometheus-stack` for §7 — the harness falls back to scraping
`/metrics` directly if Prometheus is absent.

---

## 3. Trust material

Reuse the existing PKI. Do not generate a second one — the whole point is to test the
signatures CI actually produces.

```bash
# The trust anchor is the ROOT, per ADR-0003. Not the intermediate.
export CA_CRT="../../container-vulnerability-exemption/trust/ca.crt"
bash 10-trust/render-attestor.sh "$CA_CRT" > 20-policies/_attestor-certs.yaml
```

`render-attestor.sh` inlines the PEM into the `notary.certs.value` block with correct YAML
indentation, which is the single most common way these policies fail to apply.

Two ways to supply the cert, both tested:

1. **Inline `value:`** — what `render-attestor.sh` produces. Simple, but the PEM is in the
   policy object, so rotating the anchor is a policy change.
2. **`expression:`** — a CEL expression, so the cert can come from a `ConfigMap` via the
   global context. Decouples anchor rotation from policy rollout. `20-policies/ivpol-notary-configmap.yaml`
   shows this; worth testing because it is the closest Kyverno gets to the "one trust store,
   rotate independently" property ADR-0003 wanted.

**Test the anchor before writing any policy** — a chain that does not verify locally will not
verify at admission, and the local error message is far better:

```bash
bash 10-trust/verify-locally.sh "$SIGNED_IMAGE" "$CA_CRT"
```

This sets up a notation trust policy with `level: strict` and `trustedIdentities: ["*"]` —
deliberately identical to what Kyverno hardcodes (F1) — so a local pass is a genuine predictor
of an admission pass.

---

## 4. Test fixtures — the four images

Everything downstream needs these four. `scripts/build-fixtures.sh` builds and pushes them.

| Fixture | What it is | Expected verdict |
|---|---|---|
| `IMG_SIGNED` | Trivial image in the SOE registry, signed with the full chain (leaf → intermediate → root) via the existing `sign-image.sh` | **Admit** |
| `IMG_UNSIGNED` | Same image, different tag, never signed | **Deny** |
| `IMG_BADSIG` | Signed by a *different* root — generate a throwaway CA with `gen_signing_certs.sh` into a scratch dir | **Deny** (this is the test that proves the trust store is doing work, not just presence-of-signature) |
| `IMG_VENDOR` | A third-party image (e.g. `docker.io/library/nginx`) that will never be signed | **Deny**, then **Admit via exception** |

A fifth, for F1: `IMG_ROGUE` — signed with a leaf issued from **our real intermediate** but
with a different DN (`CN=not-the-soe-signer`). Kyverno **will admit it**. That is not a bug
report, it is the demonstration that `TrustedIdentities: ["*"]` means what it says, and it is
the single most useful artefact this exercise can produce for the ADR.

> Per ADR-0003, `gen_signing_certs.sh` writes keys to disk and is test material only. Use a
> scratch directory, and do not let the real intermediate key anywhere near a runner. If
> policy forbids issuing `IMG_ROGUE` from the real intermediate, build the equivalent with a
> throwaway three-tier PKI and trust *that* root in a scratch policy — the finding is
> identical.

---

## 5. Functional tests — the policy itself

Run in a dedicated namespace, `validationActions: [Audit]`, `failurePolicy: Ignore`, until
5.9. `40-functional/run.sh` drives all of these and writes a results table.

| # | Scenario | Apply | Expect |
|---|---|---|---|
| 5.1 | Happy path | `IMG_SIGNED` pod, `20-policies/ivpol-notary.yaml` | Pod admitted; `PolicyReport` result `pass` |
| 5.2 | Unsigned | `IMG_UNSIGNED` pod | `fail`; message from `validations[0].message` |
| 5.3 | Wrong root | `IMG_BADSIG` pod | `fail`, error mentions trust store / certificate chain |
| 5.4 | Out of scope | `IMG_VENDOR` pod, policy scoped to SOE registry glob | **`skip`** — `matchImageReferences` did not select it. Confirm the report says skip, not pass. This is F3's blast radius made visible. |
| 5.5 | Catch-all / fail-closed | Add `20-policies/ivpol-catchall.yaml` (`matchImageReferences: ["**"]`), retry `IMG_VENDOR` | `fail`. On v1.19 also test `validationConfigurations.required: true` on its own and confirm it produces `image ... is not verified: no policy performed a signature or attestation check on it` |
| 5.6 | Scoping | Same policy, `matchConstraints` limited to one namespace via `matchConditions`, `NamespacedImageValidatingPolicy` variant | Enforced in-scope, silent out of scope |
| 5.7 | Revocation egress (F2) | Re-issue a leaf **with** a CDP pointing at an unreachable URL, sign, admit | Predict: fails under `LevelStrict`. If it passes, note the notation-core-go behaviour and re-check on the target version — this determines whether adding CRLs to the PKI would break admission |
| 5.8 | Annotation forgery (F4, v1.18.x only) | Create a pod carrying a hand-written `kyverno.io/image-verification-outcomes` annotation claiming a pass, for `IMG_UNSIGNED`. Then repeat with the **mutating** webhook's `objectSelector` narrowed so it does not match | First: expect overwrite → deny. Second: **if it admits, that is a finding that rules out 1.18.x for enforcement** |
| 5.9 | Enforcement | Flip `validationActions: [Deny]` | `kubectl apply` of the unsigned pod is rejected at the API server with the policy message |
| 5.10 | Digest mutation | `mutateDigest: true`, submit a **tag** reference | Pod's `spec.containers[].image` is rewritten to `...@sha256:...`. Check that this composes with the base-comparison-by-digest model in `compliance_check.py` rather than fighting it |
| 5.11 | Attestations | Attach an SBOM as an OCI 1.1 referrer, `attestations[].referrer.type`, `verifyAttestationSignatures(...)` | Verifies. Note the Notary path supports **referrer** attestations only — `intoto` is Cosign-only and errors with `notary verifier only supports oci 1.1 referrers as attestations` |
| 5.12 | Pod controllers | Deployment / CronJob with `IMG_UNSIGNED` | Denied at the controller level via autogen. Confirm which `podControllers` are covered — `spec.autogen.podControllers.controllers` |
| 5.13 | Expired leaf | Sign with a leaf whose validity has passed | Denied (`LevelStrict` enforces `TypeExpiry`). This is ADR-0001's "coarse revocation for free" behaving identically under Kyverno |

---

## 6. Exceptions — how they actually work

### 6.1 The model

For `ImageValidatingPolicy`, a `PolicyException`:

- is a **namespaced** object (`policies.kyverno.io/v1`, `kind: PolicyException`);
- names its targets via `spec.policyRefs[].{name,kind}` — `kind: ImageValidatingPolicy`;
- selects resources via `spec.matchConditions[]`, **CEL over the admission request**;
- when it matches, the **entire policy is skipped for that resource** — the short-circuit
  happens in `compiledPolicy.Evaluate` *before* any registry call, so an exempted pod costs
  nothing at admission (relevant to §7 P8);
- produces a `skip` (or `pass`, via `reportResult`) in the `PolicyReport`.

**A trap:** the `spec.images` and `spec.allowedValues` fields exist on the CRD and are
documented as exposing `exceptions.allowedImages` / `exceptions.allowedValues` to CEL. Those
variables are registered for `ValidatingPolicy`, `MutatingPolicy` and `GeneratingPolicy`
— **not for `ImageValidatingPolicy`**. The IVP compiler only compiles a `PolicyException`'s
`matchConditions`. So for image exemptions you write the image match yourself:

```yaml
matchConditions:
  - name: vendor-nginx
    expression: >-
      object.spec.containers.exists(c, c.image.startsWith('docker.io/library/nginx:'))
```

Test 6.2 asserts this explicitly, because writing `spec.images` and expecting it to work is
the obvious mistake and it fails **open**-looking (the exception simply never matches, so the
policy denies — which at least fails safe, but is baffling to debug).

### 6.2 Enablement and blast radius

`--enablePolicyException=false` is the default. `--exceptionNamespace` restricts where
exceptions are honoured; `'*'` means anywhere. **Set it to a single namespace** (e.g.
`kyverno-exceptions`) — otherwise any namespace-admin who can create a `PolicyException` in
their own namespace can exempt themselves from a cluster policy, and `spec.matchConditions` is
unrestricted CEL, so they can exempt *anything*, not just their own workloads. This is the
Kyverno-side equivalent of the fleet-wide-privilege problem ADR-0003 solved with a separate
CA, and it needs the same seriousness: namespace restriction plus RBAC plus a
`ValidatingPolicy` over `PolicyException` objects themselves. `30-exceptions/guardrail-vpol.yaml`
is a starting point — it requires `properties.ticket` and an `expiresAt` within 90 days.

### 6.3 Expiry (F5)

**v1.19+:**

```yaml
spec:
  expiresAt: "2026-11-15T00:00:00Z"
  properties:
    reason: "CVE-2026-1234 accepted, no fixed version upstream"
    ticket: "SEC-4471"
    approved-by: "security-team"
```

**v1.18.2:** no `expiresAt`. The composed pattern — a `ClusterCleanupPolicy` that deletes
`PolicyException` objects past a label-encoded date — is in
`30-exceptions/expiry-cleanuppolicy-1.18.yaml`. Test that it actually fires, and note the
window between "expired" and "deleted" is one cleanup interval, during which the exemption is
still live.

### 6.4 Tests

| # | Scenario | Expect |
|---|---|---|
| 6.1 | Exception with no `enablePolicyException` | Object applies, exemption ignored, pod still denied |
| 6.2 | `spec.images` only, no `matchConditions` | **Exemption does not apply.** Then add `matchConditions` and confirm it does |
| 6.3 | Exception in a namespace outside `--exceptionNamespace` | Ignored |
| 6.4 | Expiry (v1.19) | Set `expiresAt` a few minutes out; poll pod creation; **measure the lag** between the timestamp and the first denial — expiry is applied on list-during-reconcile, not by a timer |
| 6.5 | Expiry (v1.18 composed) | Cleanup policy deletes it; measure the same lag, which will be much larger |
| 6.6 | Scope creep | An exception whose `matchConditions` is `true` | Exempts everything the policy matches — confirm, then confirm the guardrail policy in 6.2 blocks it |
| 6.7 | Fan-out reality check | Apply the same exception to 3 clusters by hand, then change it on 2 | The manual drift ADR-0002 rationale 2 is about. Not a pass/fail — a stopwatch and an honest note |
| 6.8 | Report visibility | `kubectl get polr -A -o wide` | Exempted resource shows `skip` with the exception name in `properties`. This is the audit trail that replaces Wiz's central ignore-rule list |

---

## 7. Performance test scenarios

### 7.0 What determines the cost

Before designing the runs, the cost model, from the source:

1. **Round trips.** Cold-cache Notary verification = manifest resolve + referrers list +
   signature manifest + signature blob. Registry RTT dominates; the crypto is a chain
   validation and is microseconds.
2. **Cache.** `imageVerifyCacheEnabled` defaults **true**, TTL 60m, max **1000 entries**. The
   key is `policyUID ; policyResourceVersion ; ruleName ; imageRef`
   (`pkg/image/verification/cache/client.go`). Two consequences: **any edit to the policy bumps
   its `resourceVersion` and invalidates every entry for it**, and 1000 entries is small for a
   200-cluster fleet's image diversity — an LRU-thrashing fleet gets cold-path latency
   permanently.
3. **Webhook count.** With `mutateDigest` on you pay two webhook calls per pod. On 1.18.2 the
   mutating one does the registry work (F4); on `main` the mutating one is only registered if
   `mutateDigest` is set, so turning it off removes a whole webhook from the path.
4. **Fan-out.** Cost scales with *distinct images per pod* (containers + initContainers +
   ephemeralContainers), not pods.
5. **Exceptions are free.** A matched exception short-circuits before any registry call.
   Cost is one CEL evaluation per exception per request — cheap, but linear in exception count.
6. **Background scan** re-verifies every matched image in the cluster every
   `backgroundScanInterval` (default 1h) from the **reports controller**, a completely separate
   registry-egress path from admission.

### 7.1 Instrumentation

Ground truth is the **API server's** view, not Kyverno's — it is the number that actually
delays a `kubectl apply`:

```promql
# p50/p95/p99 per webhook, and the mutate/validate split
histogram_quantile(0.99, sum by (le, name, type) (
  rate(apiserver_admission_webhook_admission_duration_seconds_bucket{name=~"ivpol\\..*"}[1m])))

# rejections
sum by (name) (rate(apiserver_admission_webhook_rejection_count{name=~"ivpol\\..*"}[1m]))
```

Kyverno's own view, for attributing time inside the policy:

```promql
histogram_quantile(0.99, sum by (le, policy_name, result) (
  rate(kyverno_image_validating_policy_execution_duration_seconds_bucket[1m])))

sum by (policy_name, result) (rate(kyverno_image_validating_policy_results[1m]))
rate(kyverno_admission_review_duration_seconds_sum[1m]) / rate(kyverno_admission_review_duration_seconds_count[1m])
rate(kyverno_client_queries[1m])
```

Plus `container_cpu_usage_seconds_total` / `container_memory_working_set_bytes` for the
admission and reports controllers, and `apiserver_request_duration_seconds` for `pods:create`
as the end-to-end number.

`50-perf/collect.sh` scrapes and diffs these before/after each run and emits a row; it works
against Prometheus if `PROM_URL` is set and falls back to direct `/metrics` scrapes if not.
`50-perf/loadgen.sh` is the driver — parallel pod creation at a configurable arrival rate,
with per-request wall-clock timing so you have a client-side distribution independent of any
metric.

**Every run is a triplet:** policy absent (control) → policy in `Audit` → policy in `Deny`.
Without the control you cannot separate Kyverno's cost from the cluster's baseline, and on
these clusters the Wiz webhook is already in the path.

### 7.2 Scenarios

**Latency and throughput**

| ID | Scenario | Variable | What it answers |
|---|---|---|---|
| P1 | Control | No IVP | Baseline pod-create latency with Kyverno config policy + Wiz already in the path |
| P2a | Cold cache, single pod | Cache disabled (`imageVerifyCacheEnabled=false`) | True per-verification cost. The number to quote |
| P2b | Cold cache, `mutateDigest: false` | vs P2a | Cost of the second webhook. On `main` this removes it entirely; on 1.18.2 it does not (F4) — worth confirming both |
| P3 | Warm cache | Same image ×100 | Cache hit cost, and the hit/miss ratio you can expect steady-state |
| P4 | Cache thrash | 1500 distinct image digests, `maxSize=1000` | Does the fleet's image diversity fit in the cache? Sweep `maxSize` 1000/5000/20000 and find where p99 stops improving |
| P5 | Throughput ramp | 1 → 10 → 50 → 200 pods/s | Where p99 knees. Watch `kyverno_client_queries` and admission controller CPU together |
| P6 | Container fan-out | 1, 3, 10 containers/pod, distinct images | Confirms cost is per distinct image; sets the worst-case for sidecar-heavy workloads |
| P7 | Policy count | 1, 5, 20 IVPs matching the same pod | Do N policies mean N registry fetches for the same image, or is the image data shared within a request? Read `imagedataloader.ImageContext` reuse — then measure, because the answer changes how you'd structure fleet policy |
| P8 | Exception count | 0, 50, 500 exceptions on one policy | Per-request CEL cost of exception matching. Also the closest proxy for "what would 200 clusters × M exemptions feel like" |
| P9 | Registry latency | Inject 100ms/500ms RTT (netem or a proxy) | Sensitivity to registry health — the thing most likely to differ between the lab and a real region |

**Failure modes**

| ID | Scenario | How | What to record |
|---|---|---|---|
| P10 | Registry unreachable | NetworkPolicy blackholing the registry from the admission controller | `failurePolicy: Fail` → do pod creates stop fleet-wide? `Ignore` → do unsigned images get in? Is the cache still serving? **This is the Kyverno analogue of ADR-0002 open risk 1, and the reason that risk is listed as the most important thing to confirm before BLOCK.** Answer it here for Kyverno, and it becomes the baseline to compare Wiz against |
| P11 | Webhook timeout | `webhookConfiguration.timeoutSeconds: 1` with 500ms registry RTT | Timeout → `failurePolicy` decides. Confirm k8s caps at 30s and that Kyverno's per-policy value is what lands on the webhook config |
| P12 | Kyverno down | Scale admission controller to 0 under load | Time to first failure, and behaviour of both `failurePolicy` settings. **Then repeat with the Wiz webhook also failing** — two independent fail-closed webhooks is the accepted cost in ADR-0002 and nobody has measured what it looks like |
| P13 | Kyverno restart under load | Rolling restart at 50 pods/s | Error window; whether the cache is cold on the new pod (it is — in-memory ristretto, per-pod, so every restart and every scale-out is a cold cache) |
| P14 | Cert expiry mid-run | Leaf expires during the run | Should flip cleanly from admit to deny. Confirms F2/5.13 under load |
| P15 | Revocation endpoint unreachable | Leaf with a CDP pointing at a blackholed host | Per F2 — measures the latency penalty of a hanging revocation check, which is the worst case: not a fast failure but a slow one, inside the webhook timeout budget |
| P16 | Forged annotation under load (1.18.x) | 5.8 at 50 pods/s | Whether the race between mutate and validate ever admits an unverified image |

**Scale**

| ID | Scenario | What to record |
|---|---|---|
| P17 | Background scan cost | Enable `evaluation.background.enabled`, 5000 existing pods, watch one full `backgroundScanInterval` | Reports-controller CPU/memory, registry QPS, and total registry calls per cluster per hour. Multiply by ~200 clusters — this is a number the registry team will care about, and it is the cost Wiz does not have because it scans centrally |
| P18 | Report volume | Same | `PolicyReport` object count and etcd size delta. At fleet scale this is the reason `reports-server` exists |
| P19 | Resource profile | P5 at the knee | Admission controller CPU/memory vs replica count; derive requests/limits and whether HPA is needed |
| P20 | Steady-state fleet sim | 200 exceptions + 20 policies + 5000 pods, 24h soak | Memory growth, cache hit ratio over a day, whether anything leaks |

### 7.3 Reporting

`50-perf/results-template.md` — one row per (scenario, version, validationAction, cache
setting) with p50/p95/p99, throughput, error count, and CPU/mem. The output that matters to
the ADR is three numbers:

1. **Added p99 admission latency, warm cache** — the steady-state tax.
2. **Added p99, cold cache** — the tax on a fresh cluster, a Kyverno restart, or a new image.
3. **Blast radius on registry outage** — from P10, for both `failurePolicy` settings.

Compare each against the Wiz admission controller measured the same way. ADR-0002 open risk 1
is currently unanswered for *both* systems; this exercise answers it for one of them, which is
worth doing regardless of which control plane wins.

---

## 8. What this can and cannot decide

It can settle: does IVP+Notary verify our real signatures, what does it cost, how does it fail,
and how do exemptions behave.

It cannot settle ADR-0002's deciding argument. Rationale 1 was **one exemption mechanism**,
and Kyverno still does not scan for vulnerabilities — a `PolicyException` answers "may this
image be admitted", not "do we accept this CVE". F5 narrows the gap (native expiry, ticket and
approver on the object) but does not close it; you would still be running a scanner with its
own ignore list. Rationale 2 — one tenant API vs ~200 etcds — is untouched by anything here.

If this exercise ends with "it works, it is fast, and the failure modes are understood", the
honest conclusion is still *ADR-0002 stands, on rationale 1 and 2 alone* — and the value
delivered is that F1 corrects a false claim in ADR-0003, F5 retires rationale 3, and §7 P10
produces the fail-open/fail-closed baseline that ADR-0002 lists as its most important open
risk.

---

## Layout

```
00-prereqs/     check-kyverno.sh, check-registry-access.sh, values-ivpol.yaml
10-trust/       render-attestor.sh, verify-locally.sh
20-policies/    ivpol-notary.yaml, ivpol-catchall.yaml, ivpol-notary-configmap.yaml,
                nivpol-namespaced.yaml, ivpol-attestation-sbom.yaml
30-exceptions/  polex-vendor.yaml, polex-expiresAt-1.19.yaml,
                expiry-cleanuppolicy-1.18.yaml, guardrail-vpol.yaml, README.md
40-functional/  run.sh, pods/
50-perf/        loadgen.sh, collect.sh, promql.md, results-template.md
scripts/        build-fixtures.sh, check-referrers.sh
```

## Sources

- [ImageValidatingPolicy | Kyverno](https://kyverno.io/docs/policy-types/image-validating-policy/)
- [Policy Exceptions | Kyverno](https://kyverno.io/docs/exceptions/)
- [Notary | Kyverno](https://kyverno.io/docs/policy-types/cluster-policy/verify-images/notary/)
- kyverno/kyverno `v1.18.2` and `main@1df9235` — `pkg/image/verifiers/{ivpol,cpol}/notary/`,
  `pkg/image/verification/{cache,evaluator}/`, `pkg/cel/libs/imageverify/`,
  `pkg/cel/policies/ivpol/engine/`, `pkg/cel/engine/exception.go`, `pkg/metrics/ivpol.go`,
  `cmd/internal/flag.go`, `charts/kyverno/values.yaml`, `config/crds/policies.kyverno.io/`
- notaryproject/notation-go `v1.3.2` — `verifier/trustpolicy/trustpolicy.go`, `verifier/verifier.go`
