# ImageValidatingPolicy — performance results

**Cluster:** _____ · **Kyverno:** _____ · **k8s:** _____ · **Registry:** _____ · **Date:** _____
**Admission controller replicas:** _____ · **Other pod webhooks in path:** _____ (list; note which are fail-closed)

Every row needs the cache configuration recorded, because a latency number without it is
meaningless — the cache key is `policyUID;resourceVersion;ruleName;imageRef` and the cache is
per-pod, in-memory. A policy edit or a Kyverno restart resets it.

## Run conditions

| | |
|---|---|
| `imageVerifyCacheEnabled` | |
| `imageVerifyCacheMaxSize` | |
| `imageVerifyCacheTTLDuration` | |
| `mutateDigest` | |
| `failurePolicy` | |
| `validationActions` | |
| `webhookConfiguration.timeoutSeconds` | |
| Background evaluation | |
| Load mode | server dry-run / real pods |

## Latency and throughput

| ID | Scenario | n | p50 ms | p95 ms | p99 ms | max ms | thr /s | mutate p99 | validate p99 | Notes |
|---|---|---|---|---|---|---|---|---|---|---|
| P1 | Control, no IVP | | | | | | | — | — | baseline incl. existing webhooks |
| P2a | Cold cache, single pod | | | | | | | | | the per-verification cost |
| P2b | Cold cache, `mutateDigest:false` | | | | | | | | | delta vs P2a = 2nd webhook cost |
| P3 | Warm cache | | | | | | | | | |
| P4a | 1500 images, maxSize 1000 | | | | | | | | | hit ratio: |
| P4b | 1500 images, maxSize 5000 | | | | | | | | | hit ratio: |
| P4c | 1500 images, maxSize 20000 | | | | | | | | | hit ratio: |
| P5a | 10 pods/s | | | | | | | | | CPU: |
| P5b | 50 pods/s | | | | | | | | | CPU: |
| P5c | 200 pods/s | | | | | | | | | CPU: |
| P6a | 1 container | | | | | | | | | |
| P6b | 3 distinct images | | | | | | | | | |
| P6c | 10 distinct images | | | | | | | | | |
| P7a | 1 IVP | | | | | | | | | registry calls: |
| P7b | 5 IVPs | | | | | | | | | registry calls: |
| P7c | 20 IVPs | | | | | | | | | registry calls: |
| P8a | 0 exceptions | | | | | | | | | |
| P8b | 50 exceptions | | | | | | | | | |
| P8c | 500 exceptions | | | | | | | | | |
| P9a | +100ms registry RTT | | | | | | | | | |
| P9b | +500ms registry RTT | | | | | | | | | |

**P7 is the one to read carefully.** If 20 policies matching the same pod produce 20× the
registry calls for the same image, fleet policy has to be one big policy rather than many small
ones — which changes how exemptions and rollout staging can be structured. Read
`kyverno_client_queries` and the registry's own request log, not just latency.

## Failure modes

| ID | Scenario | failurePolicy | Result | Time to first failure | Recovery | Notes |
|---|---|---|---|---|---|---|
| P10a | Registry unreachable | Ignore | | | | did unsigned images get in? |
| P10b | Registry unreachable | Fail | | | | did all pod creates stop? |
| P10c | Registry unreachable, warm cache | Fail | | | | does the cache keep serving? for how long? |
| P11 | Webhook timeout 1s | Ignore / Fail | | | | |
| P12a | Kyverno scaled to 0 | Ignore | | | | |
| P12b | Kyverno scaled to 0 | Fail | | | | |
| P12c | Kyverno **and** Wiz both down | Fail | | | | the ADR-0002 dual-webhook risk, measured |
| P13 | Rolling restart at 50/s | Fail | | | | cold-cache latency on the new pods: |
| P14 | Leaf expires mid-run | Fail | | | | clean flip to deny? |
| P15 | Revocation endpoint blackholed | Fail | | | | latency penalty: ______ ms — a HANG inside the timeout budget is worse than a fast fail |
| P16 | Forged annotation at 50/s (1.18.x) | Fail | | | | **any admit here rules out 1.18.x for enforcement** |

> P10 is the direct analogue of ADR-0002 open risk 1 — "Wiz admission controller behaviour
> when the Wiz backend is unreachable ... is not yet verified, and matters more than usual
> given the proxy-allowlist egress." Fill this table in for Kyverno and you have the first
> half of that answer, plus the method to get the second half.

## Scale

| ID | Metric | Value | Notes |
|---|---|---|---|
| P17 | Reports controller CPU during background scan | | |
| P17 | Reports controller peak memory | | |
| P17 | Registry requests per scan cycle | | ×200 clusters = ______ req/h fleet-wide |
| P17 | Scan wall time, 5000 pods | | vs `backgroundScanInterval` — does it finish? |
| P18 | PolicyReport object count | | |
| P18 | etcd size delta | | |
| P19 | Admission CPU at the P5 knee | | |
| P19 | Admission memory at the P5 knee | | |
| P19 | Recommended requests/limits | | |
| P20 | 24h memory growth | | |
| P20 | 24h steady-state cache hit ratio | | |

## The three numbers

1. **Added p99 admission latency, warm cache:** ______ ms (P3 − P1)
2. **Added p99 admission latency, cold cache:** ______ ms (P2a − P1)
3. **Blast radius on registry outage:** ______ (P10)

Same three for the Wiz admission controller, measured identically:

1. ______ ms  2. ______ ms  3. ______

## Conclusions

_What changes in the ADR as a result. Be specific about which rationale each finding touches:_

- _F1 (no Notary identity pinning in Kyverno) — corrects ADR-0003 Consequences, removes one of the two revisit paths._
- _F5 (`expiresAt` in v1.19) — retires ADR-0002 rationale 3._
- _P10 — first real data on ADR-0002 open risk 1._
- _Rationale 1 (one exemption mechanism) and rationale 2 (fan-out) — did anything here move them? If not, say so plainly._
