# Implementation Plan — image-admission-engine (review before build)

Brief: [`requirements.md`](requirements.md). **Nothing implemented yet** — this repo currently
holds only that file. This document evaluates the brief, calls out decisions I've made
unilaterally (reusing settled reasoning from the sibling
[`container-vulnerability-exemption`](../../container-vulnerability-exemption/) POCs), and lists
open questions that change the architecture depending on your answer. Answer inline and I'll
build from it.

---

## 0. Is the brief simple yet effective?

Short answer: **the model is right, the spec is missing the parts that made the Kyverno POC
hard.** Priority-ordered `imagePrefix` rules (SG-style, first match wins) and a
`PolicyException` CRD with expiry/approver/jira/reason are proven shapes — they're close to
[`exemption.defs.json`](../../container-vulnerability-exemption/unikube/schemas/exemption.defs.json),
which already survived one rework. Per-container checking of
`initContainers`/`containers`/`ephemeralContainers` is the correct granularity, and if exceptions
are matched **per image** (see §1.4) this design fixes the single sharpest bug the Kyverno POC
had to work around: `polex-vendor.yaml` in that repo exists entirely to stop one exempted sidecar
from silently admitting an unsigned image next to it, because Kyverno `PolicyException` skips the
*policy for the resource*, not the image. A purpose-built controller doesn't inherit that
footgun — that's the actual "best of both" argument for building this instead of adopting IVP
wholesale.

What's underspecified, in order of how much it changes the architecture:

| Gap | Why it matters | Where it's resolved below |
|---|---|---|
| Does a `PolicyException` match apply to one image or the whole pod? | Kyverno's version of this bug is documented and tested for in the sibling repo (`poc/30-exceptions/README.md`, test 6.6). Getting this wrong reintroduces the exact bypass this project exists to avoid. | §1.4 — per-image, not per-pod. Locked in. |
| Catch-all rule (`imagePrefix: "*"`, priority 999) means **every** image must be signed, including cluster infrastructure. | The Kyverno POC's own `10-ivp-soe-signed-simple.yaml` header documents this landmine: CoreDNS, kube-proxy, the VPC CNI, CSI drivers, and Kyverno's own images never carry an org signature, and without a chart-level exclusion a node scale-up can't start networking. This brief has no equivalent of Kyverno's `resourceFilters` default. | §2, Q1 — needs your answer. |
| `AUDIT`/`BLOCK` (what happens to the workload) is conflated with what happens when the **controller itself** is unreachable. | `exemption.defs.json`'s `failure_policy` field exists precisely because these are independently dangerous: `BLOCK` + `Fail` + an outage = cluster-wide inability to schedule anything. | §1.3 — separate knob, default `Ignore`. |
| "blazing fast" with no caching strategy specified. | Registry signature fetch is a network round-trip on the pod-create path. Without a decision to cache by **digest** (immutable) rather than tag, every pod create pays that latency, repeatedly, for the same image. | §2, Q6. |
| Audit-record storage and the reviewer UI's backing store aren't named. | This is the single biggest unscoped piece of the ask — it's a second stateful service, not a webhook detail. | §2, Q2. |
| Metric label cardinality. | "Comprehensive" Prometheus metrics with raw image name or digest as a label is a cardinality bomb — Prometheus best-practice violation, and it's an easy mistake to make by literally following the brief's "on containers being blocked/excepted/signed" language too directly. | §3.6. |
| `imagePrefix` matching semantics (substring vs. boundary-safe prefix). | `exemption.defs.json`'s `signed_image_prefixes` requires a trailing `/` for exactly this reason: `some.vendor.registry.domain` would also match `some.vendor.registry.domain.evil.com` and `some.vendor.registry.domain-scratch/`. The brief's example YAML doesn't show trailing slashes. | §1.5. |
| Pod vs. CronJob as the admission hook target. | Webhooks fire on the resource actually persisted. A CronJob's pods come from a Job the CronJob controller creates — there's no separate "CronJob has bad images" moment to intercept if Pod-level admission already covers it. | §2, Q5 — recommend Pod-only. |

None of this makes the brief wrong. It makes it a first draft of the *policy model*, not yet an
implementation spec — which is exactly what a review-before-build pass is for.

---

## 1. Decisions I'm treating as settled (carried over, not re-litigated)

These reuse reasoning the sibling repo already worked out and tested against; re-deriving them
here would just reproduce the same conclusions slower.

**1.1 Signature scheme: Notation (Notary Project v2) only, no cosign.**
Matches the brief's own wording ("so that Notation can verify image signatures") and the sibling
repo's [ADR-0003 reasoning](../../container-vulnerability-exemption/image-signing/README.md):
enterprise X.509 PKI, offline-capable via ORAS, no dependency on Sigstore's Fulcio/Rekor. Use
`notation-go` directly rather than shelling out to the CLI.

**1.2 Trust anchor is the CA root, never an intermediate.**
Pinning an intermediate is certificate pinning that breaks on every intermediate rotation — the
same reasoning as [`trust/README.md`](../../container-vulnerability-exemption/trust/README.md).
`ImageTrust` rule `ca:` fields hold roots.

**1.3 `mode` (AUDIT/BLOCK) and `failurePolicy` (Ignore/Fail) are separate fields, not one.**
`mode` governs what happens to a workload that fails verification. `failurePolicy` governs what
the API server does when this controller can't answer at all (crash, timeout, unreachable
registry). Default `mode: AUDIT`, default `failurePolicy: Ignore` (fail-open) so that a broken
deployment of this controller can't itself take down pod scheduling cluster-wide until it's been
proven safe to flip.

**1.4 `PolicyException` matches are evaluated per image, not per pod.**
A pod with three containers where one matches an exception and two don't: the two still get
verified. This is the fix for the bug §0 describes. Concretely: admission logic walks
`initContainers + containers + ephemeralContainers` and evaluates each image independently against
(exceptions, then trust rules) — there is no "exception matched, skip the rest of the pod" path
anywhere in the code.

**1.5 `imagePrefix` matching is boundary-safe, not raw substring.**
A prefix must match on a `/`, `:`, or `@` boundary (or exact end-of-string) — the same hazard
`exemption.defs.json` documents. I'll normalize this at admission-time (compare path segments)
rather than pushing a trailing-slash convention onto CRD authors, since that convention is easy
to violate silently in this brief's own example YAML (`"some.vendor_1.registry.domain"` has no
trailing `/`).

**1.6 Verification is keyed by digest, not tag.**
A pod's `image:` is resolved to a digest (via the registry API, or read directly if already
digest-pinned) before verification and before cache lookup. Tags are mutable; caching or
verifying by tag would let a re-pointed tag serve a stale verification result.

---

## 2. Open questions — need your answer before I start building

**Q1 — Default-exclude namespaces / infra bypass.**
Every image needs *some* signer under the brief's catch-all model, but CoreDNS, kube-proxy, VPC
CNI, CSI drivers, and this controller's own images will never carry your org's Notation
signature. Kyverno's chart handles this with a `resourceFilters` default excluding
`kube-system`/`kube-public`/`kube-node-lease`/`kyverno`. Do you want:
  - (a) the same hard-coded namespace exclusion list, configurable via Helm values, or
  - (b) no exclusion — instead require every infra image to get its own `ImageTrust` rule
    pointing at the relevant vendor CA (AWS's ECR public images are unsigned by Notation today,
    so this likely means "exempt via `PolicyException` instead"), or
  - (c) both — namespace exclusion for kube-system-class namespaces, `PolicyException` for
    everything else.
  (c) is what I'd default to absent your input, since it mirrors what the Kyverno POC ended up
  needing in practice, but it's your call because it's a real security-boundary decision, not
  an implementation detail.

**Q2 — Audit record storage + reviewer UI backing store.**
The brief asks for "all admission decisions recorded as audit events" plus a UI that reads them
and comprehensive Prometheus metrics. These are different durability requirements:
  - Prometheus metrics: counters, fine as-is, no design question.
  - Audit *events with details* (image, digest, rule matched, exception matched, decision,
    namespace, workload, timestamp) queried by a UI: this needs a real datastore. Options,
    roughly in order of operational simplicity:
    1. Structured JSON logs (stdout) → your existing log pipeline (CloudWatch/Loki/etc.) → UI
       queries that backend. Zero new stateful component; UI is a thin query layer. Weakest if
       you don't already have durable log retention wired up cluster-wide.
    2. A small embedded DB (SQLite via a PVC, or an in-cluster Postgres) written directly by the
       webhook, read by the UI. Self-contained, no dependency on log infra, but it's a new
       stateful service to run and back up.
    3. Kubernetes `Event` objects / a dedicated `ImageAdmissionRecord` CRD. Fits "k8s-native" but
       etcd is the wrong place for high-volume, short-retention audit data — every pod create in
       a busy cluster is a write, and CRD storage doesn't have a TTL primitive by default (you'd
       need a cleanup controller, same shape as the Kyverno POC's `ClusterCleanupPolicy` problem
       on 1.18).
  Which of these fits your existing platform? This is the one decision that most changes the
  shape of the "Reviewer UI" component (§3.5) and the helm chart's service list.

**Q3 — Registry credential resolution scope for v1.**
The brief says "use the repository secrets specified in pod manifest… if ECR, use IRSA." Full
generality here (arbitrary `imagePullSecrets`, every registry's auth scheme, IRSA for ECR,
workload-identity equivalents for GCR/ACR) is a lot of surface for a v1. Do you want v1 scoped to
**ECR-via-IRSA + `imagePullSecrets` (dockerconfigjson) only**, with other registries treated as
"credential resolution not implemented, fail per `failurePolicy`"? I'd recommend this scope cut
explicitly rather than silently under-building it.

**Q4 — Reviewer UI stack.**
No preference stated in the brief. Given "deploy to clusters" via the same Helm chart, I'd default
to a small Go backend (reuses the admission controller's data types) serving a lightweight static
frontend (htmx or a minimal React build) rather than pulling in a separate frontend toolchain —
but tell me if you already have a UI stack standard for in-cluster tools.

**Q5 — Admission hook target: Pods only, or also CronJob/Deployment/etc.?**
I'd recommend webhook `resourceRules` on `pods` (CREATE) and the `pods/ephemeralcontainers`
subresource (UPDATE, since ephemeral containers are added via subresource update, not pod
creation) — and nothing else. A CronJob's images are only real once a Job creates a Pod; hooking
CronJob/Deployment/etc. directly adds surface without adding coverage, since the Pod they
eventually create still goes through this webhook. Confirm this matches your intent for "when a
pod/cronjob is deployed."

**Q6 — Verification cache TTL and scope.**
Proposing: an in-memory LRU keyed by image digest, value = (verified bool, matched rule/exception,
timestamp), TTL default 1h, size-bounded (configurable, default e.g. 10k entries), invalidated
early if the matching `ImageTrust`/`PolicyException` CRDs change (via informer resync — a CA
rotation or a revoked exception must not serve a stale "trusted" verdict past the next resync).
Reasonable, or do you want cache entries to survive pod restarts (i.e., backed by something
external rather than in-memory-per-replica)? In-memory-per-replica is simpler and meets "no
noticeable latency" for the steady state (repeat image across many pods, which is the common
case); it just means a cold cache after a rolling restart of the controller itself.

---

## 3. Proposed architecture

```
                        ┌───────────────────────────────┐
 kube-apiserver ───────▶│  admission webhook (validate)  │──▶ ADMIT / DENY
  (Pod CREATE,          │  - resolves images per container│
   pods/ephemeral       │  - digest resolution + cache    │
   containers UPDATE)   │  - exception match (per image)  │
                        │  - trust rule match + verify     │
                        │  - always emits audit event      │
                        └──────────────┬──────────────────┘
                                       │ watches (informer)
                     ┌─────────────────┼─────────────────┐
                     ▼                 ▼                 ▼
             ImageTrust CRDs   PolicyException CRDs   audit sink (Q2)
                                                             │
                                                             ▼
                                                    reviewer UI (reads
                                                    audit sink + exposes
                                                    /metrics already on
                                                    the webhook pod)
```

**3.1 CRDs**

```go
// ImageTrust: cluster-scoped, one object (or several, merged by priority — see below).
type ImageTrustRule struct {
    Priority    int      `json:"priority"`              // lower wins, first match, SG-style
    Description string   `json:"description,omitempty"`
    ImagePrefix []string `json:"imagePrefix"`            // boundary-safe match, see §1.5
    CA          string   `json:"ca"`                     // PEM, root only (§1.2)
}

type ImageTrustSpec struct {
    Rules []ImageTrustRule `json:"rules"`
}

// PolicyException: namespaced or cluster-scoped — recommend namespaced so a team can
// self-serve within RBAC boundaries the platform team already controls, same as Kyverno's
// --exceptionNamespace convention.
type PolicyExceptionSpec struct {
    ImagePrefix []string    `json:"imagePrefix"`
    Expiry      metav1.Time `json:"expiry"`
    ApprovedBy  string      `json:"approvedBy"`
    JiraTicket  string      `json:"jiraTicket"`
    Reason      string      `json:"reason"` // enum: RISK_ACCEPTED | FALSE_POSITIVE
}
```

Open sub-question folded into Q1/Q2 territory but worth flagging now: should `ImageTrust` be a
single singleton object (simplest, matches the brief's one-YAML-file example) or allow multiple
objects merged by `priority` across objects (lets different teams own different rules under
RBAC, closer to how `PolicyException` would work)? Defaulting to **allow multiple objects,
merged and sorted by priority at watch-time**, since it costs nothing extra in the controller and
avoids a forced migration later if you want federated ownership.

**3.2 Admission flow (per workload)**

```
for each image in initContainers + containers + ephemeralContainers:
    digest := resolve(image)                      # registry HEAD/manifest call, or already digest-pinned
    if cache.hit(digest): use cached verdict; continue

    if any PolicyException matches image (prefix, not expired):
        verdict := SKIPPED_EXEMPT (record exception name, ticket, approver)
    else:
        rule := first ImageTrust rule matching image, by priority
        if rule == nil:
            verdict := BLOCKED_NO_MATCHING_RULE   # catch-all should prevent this if configured per Q1
        else:
            verdict := notation_verify(digest, rule.CA)   # SIGNED_TRUSTED or SIGNED_UNTRUSTED/UNSIGNED

    cache.put(digest, verdict)
    emit_audit_event(pod, image, digest, verdict, rule/exception matched)

decision := BLOCK if (mode == BLOCK and any verdict is not SIGNED_TRUSTED/SKIPPED_EXEMPT) else ADMIT
# audit event is written regardless of decision, and regardless of mode — this is non-negotiable
# per the brief ("MUST be recorded... even in BLOCK mode")
```

**3.3 Verification engine**
`go-containerregistry` (or `oras-go`) for registry/manifest/digest resolution and pulling the
Notation signature artifact; `notation-go` for the actual chain verification against the matched
`ImageTrust` rule's CA. Keep this behind an interface (`Verifier`) from day one — even though
Notation-only is the decision (§1.1), a fake/no-op verifier is needed for unit tests that don't
want to spin up a real registry.

**3.4 Registry credential resolution** (scope per Q3)
Resolve in this order per image: (1) `imagePullSecrets` on the pod spec / referenced service
account, decoded as `.dockerconfigjson`; (2) if the image reference host matches an ECR pattern
and no explicit secret is present, assume IRSA — the controller's own pod uses its service
account's IRSA-bound role, which must itself be granted `ecr:GetDownloadUrlForLayer` /
`ecr:BatchGetImage` / `ecr:GetAuthorizationToken` on the relevant registries via the IAM role
Terraform already provisions (per the brief, IAM roles are assumed to exist).

**3.5 Audit sink** — shape depends on Q2's answer; the webhook code should write through a small
`AuditSink` interface so the choice is a wiring decision, not a rewrite.

**3.6 Metrics** — Prometheus counters/histograms, careful on cardinality:
- `image_admission_decisions_total{decision="admit|block|audit_would_block", mode="AUDIT|BLOCK", namespace, verdict="signed_trusted|signed_untrusted|unsigned|exempt|no_matching_rule"}`
  — labels stay low-cardinality (no raw image string, no digest). `namespace` is the highest-risk
  label for cardinality growth; consider dropping it or capping it if the cluster has many
  short-lived/generated namespaces.
- `image_admission_webhook_duration_seconds` (histogram) — this is the number that proves/disproves
  "blazing fast."
- `image_admission_cache_hit_ratio` (or two counters: hits/misses) — proves the caching strategy
  from Q6 is actually working in production.
- `image_admission_registry_fetch_duration_seconds{registry}` — isolates registry latency from
  webhook overhead, since that's the part outside this codebase's control.

If you want per-image or per-exception drill-down, that belongs in the **audit records** (Q2),
queried by the UI — not in Prometheus label space.

**3.7 Reviewer UI** — reads the audit sink (Q2), exposes filter/search by namespace, image,
verdict, time range; links each record to the matched rule/exception. Stack per Q4.

**3.8 Performance**
- Watch (informer), don't `GET`, the CRDs — rule/exception set lives in memory, updated on watch
  events, never fetched from the API server on the request path.
- Digest-keyed cache (§1.6, Q6) is the main lever for "no noticeable latency" on repeat images,
  which is the overwhelmingly common case (many pods, same image, e.g. a Deployment scaling).
- `failurePolicy: Ignore` (§1.3 default) plus a request timeout budget (recommend 5–10s,
  configurable) so a slow/unreachable registry degrades to fail-open rather than hanging pod
  creation — matches the Kyverno POC's own `webhookConfiguration.timeoutSeconds: 15` caution.

---

## 4. Proposed repo layout

```
image-admission-engine/
├── cmd/
│   ├── webhook/            # admission webhook binary
│   └── reviewer-ui/        # UI backend binary (or combined with webhook — TBD per Q4)
├── api/
│   └── v1alpha1/           # ImageTrust, PolicyException types + deepcopy + CRD YAML
├── internal/
│   ├── admission/          # core flow from §3.2
│   ├── verify/             # Verifier interface + notation-go implementation
│   ├── registry/           # digest resolution, credential resolution (§3.4)
│   ├── cache/               # digest-keyed verdict cache
│   ├── audit/               # AuditSink interface + implementation(s) per Q2
│   └── metrics/
├── charts/
│   └── image-admission-engine/   # Helm chart, values.yaml, CRDs, RBAC, webhook config
├── test/
│   ├── unit/
│   └── e2e/                # envtest or kind-based, exercising the per-image exception fix (§1.4)
└── meta/
    ├── requirements.md
    └── implementation_plan.md   # this file
```

`v1alpha1` because the CRD shape (especially whether `ImageTrust` is singleton-vs-merged, §3.1)
is genuinely likely to change once this is running against real clusters.

---

## 5. Build phases

1. **CRD types + validation webhook for the CRDs themselves** (reject overlapping priorities,
   malformed CA PEM, expired-on-creation `PolicyException`, missing required
   `reason`/`approvedBy`/`jiraTicket`). No image admission logic yet — get the schema right and
   testable first, same as the sibling repo's `validate.py` role.
2. **Core admission flow in AUDIT-only mode**, no BLOCK, no UI — prove digest resolution,
   per-image exception matching (§1.4), and Notation verification against a real signed test
   image (reuse the sibling repo's `image-signing/gen_signing_certs.sh` test PKI rather than
   building a second one).
3. **Caching + metrics** — make the latency claim measurable before making it.
4. **Audit sink + reviewer UI**, per Q2/Q4.
5. **BLOCK mode + `failurePolicy` wiring**, with the e2e test specifically covering the "one
   exempted container must not admit a sibling unsigned container" case (§1.4) — this is the
   regression test that justifies the project.
6. **Helm chart + IRSA/ECR credential path** (Q3), packaged for the same clusters
   `container-vulnerability-exemption/unikube/` already targets.

---

## 6. Explicit v1 non-goals

- Cosign/keyless signatures (§1.1).
- Registries beyond ECR+IRSA and generic `imagePullSecrets` (Q3) — anything else fails per
  `failurePolicy` rather than silently succeeding.
- Multi-cluster federation of `ImageTrust`/`PolicyException` — each cluster's objects are local,
  same as the brief implies. (The *interface* repo pattern of one YAML tree rendering to many
  clusters is a possible future layer, not v1's problem.)
- Automatic CA rotation/overlap tooling — `ImageTrust.spec.rules[].ca` is a single PEM per rule;
  an overlap window (old + new CA both trusted) is achieved by adding a second rule at the same
  priority scoped narrowly, same manual pattern as `trust/README.md`'s "add-then-remove."
