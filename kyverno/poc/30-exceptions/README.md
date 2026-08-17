# PolicyException for ImageValidatingPolicy

## The one-paragraph model

A `PolicyException` is a **namespaced** object in `policies.kyverno.io`. It names target
policies in `spec.policyRefs[]` and selects resources with `spec.matchConditions[]` — CEL over
the admission request. When a condition matches, **the entire referenced policy is skipped for
that resource**, and the skip is recorded in the `PolicyReport`. The short-circuit happens in
`compiledPolicy.Evaluate` before any registry call, so an exempted pod costs one CEL
evaluation and nothing else.

## The trap: `spec.images` does not work for ImageValidatingPolicy

The CRD has `spec.images` and `spec.allowedValues`, and the docs describe them as exposing
`exceptions.allowedImages` and `exceptions.allowedValues` to CEL. Those variables are
registered in the compiler environment for `ValidatingPolicy`, `MutatingPolicy` and
`GeneratingPolicy`. They are **not** registered for `ImageValidatingPolicy` — the IVP compiler
(`pkg/image/verification/evaluator/compiler.go`) compiles a `PolicyException`'s
`matchConditions` and nothing else.

So an exception that sets only `spec.images` **never matches**, the policy is not skipped, and
the pod is denied. It fails safe, but the symptom (exception exists, is listed, does nothing)
points at the wrong things — enablement flags, namespace restriction, RBAC — and costs an
afternoon. Write the image match yourself in `matchConditions`. Test 6.2 asserts this.

## Enablement

Off by default. Both of these must be set on the admission controller:

```
--enablePolicyException=true
--exceptionNamespace=kyverno-exceptions      # or '*'
```

Helm:

```yaml
features:
  policyExceptions:
    enabled: true
    namespace: kyverno-exceptions
```

**Do not use `'*'`.** `matchConditions` is unrestricted CEL, so an exception can exempt
anything the referenced policy matches — not just workloads in the exception's own namespace.
With `'*'`, anyone who can create a `PolicyException` in any namespace can exempt the whole
cluster from image verification. Restricting to a single namespace turns "can create a
namespaced object" into "can write to one GitOps-controlled namespace", which is the control
the ADR's approval workflow actually assumes.

Layer on top of that:

1. RBAC: only the exemption pipeline's service account can write to `kyverno-exceptions`.
2. GitOps: the namespace is Argo-managed, so every exemption is a reviewed PR — which is the
   ticket-and-approver trail ADR-0002 requires.
3. `guardrail-vpol.yaml`: a `ValidatingPolicy` over `PolicyException` objects themselves,
   requiring a ticket, an approver, and an expiry within 90 days. Policy enforcing policy —
   this is the piece that makes Kyverno exemptions auditable rather than merely possible.

## Expiry

**v1.19+** — first class:

```yaml
spec:
  expiresAt: "2026-11-15T00:00:00Z"
  properties:
    reason: "CVE-2026-1234 accepted, no fixed version upstream"
    ticket: "SEC-4471"
    approved-by: "security-team"
```

Enforced in `pkg/cel/engine/exception.go` — expired exceptions are filtered out when the
policy's exception set is listed. This retires ADR-0002 rationale 3 ("Expiry is a first-class
field", listed as a Wiz-only advantage) and, via `properties`, puts the ticket and approver on
the exemption object itself.

**One caveat to measure (test 6.4):** the filter runs during *reconciliation*, not on a timer.
An exception whose `expiresAt` has passed keeps working until the policy is next reconciled.
Find out what that window actually is on an idle cluster before quoting expiry as equivalent
to Wiz's `expired_at`.

**v1.18.2** — no `expiresAt`. Compose it: `expiry-cleanuppolicy-1.18.yaml` deletes exceptions
whose `expires` label is in the past, on the cleanup controller's schedule. Same caveat, larger
window, and one more moving part per cluster — which is exactly the "pattern you assemble and
then have to keep working, per cluster" that ADR-0002 rationale 3 objected to.

## What stays true regardless of version

Exceptions are per-cluster objects. An exemption that applies to 40 clusters is 40 objects in
40 etcds, and "who is currently exempt from what, fleet-wide" is a query you have to build.
That is ADR-0002 rationale 2, it is the strongest remaining argument for Wiz, and nothing in
v1.19 touches it. Test 6.7 is a stopwatch on that reality rather than a pass/fail.
