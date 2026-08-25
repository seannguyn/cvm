# PromQL for the IVP performance runs

`collect.sh` works without Prometheus by diffing raw `/metrics` scrapes. These are for when
you have `kube-prometheus-stack` and want to watch a run live.

## The authoritative latency

The API server's own view. This is what delays a `kubectl apply`, and it includes queueing
that Kyverno's internal metric cannot see.

```promql
# p99 per webhook, split mutate vs validate
histogram_quantile(0.99,
  sum by (le, name) (
    rate(apiserver_admission_webhook_admission_duration_seconds_bucket{name=~"ivpol\\..*"}[1m])
  )
)

# the whole admission chain for pod CREATE, including Wiz and Kyverno's config policies
histogram_quantile(0.99,
  sum by (le, operation) (
    rate(apiserver_admission_controller_admission_duration_seconds_bucket{operation="CREATE"}[1m])
  )
)

# rejections
sum by (name) (rate(apiserver_admission_webhook_rejection_count{name=~"ivpol\\..*"}[1m]))
```

**Read the mutate and validate series separately.** On v1.18.x the *mutating* webhook is where
the registry work happens (F4), so a fast validate and a slow mutate is the expected shape —
and someone reading only the validate series will conclude IVP is free. On v1.19 it inverts.

## Attributing time inside the policy

```promql
histogram_quantile(0.99,
  sum by (le, policy_name, result) (
    rate(kyverno_image_validating_policy_execution_duration_seconds_bucket[1m])
  )
)

sum by (policy_name, result) (rate(kyverno_image_validating_policy_results[1m]))
```

`result` is `pass` / `fail` / `error` / `skip`. Watch `skip` during the functional runs — a
high skip rate means `matchImageReferences` is not selecting what you think it is, which on
v1.18.2 means images are being silently admitted (F3).

Subtracting this from the API server number gives Kyverno's own overhead outside policy
evaluation (deserialization, matching, report writing).

## Cache behaviour

There is **no cache hit/miss metric**. Infer it:

```promql
# registry work correlates with client queries and with execution duration
rate(kyverno_client_queries[1m])

# a bimodal execution-duration histogram IS the cache: the fast mode is hits, the slow mode
# is misses. Watch the buckets rather than the quantile.
sum by (le) (rate(kyverno_image_validating_policy_execution_duration_seconds_bucket[1m]))
```

Better: read the registry's own request log or an egress proxy's, and count requests per
admitted pod. Cold cache should be ~4 per distinct image (manifest, referrers, signature
manifest, signature blob); warm cache should be 0.

The cache is per-pod, in-memory ristretto. **Always graph it against replica count** — three
replicas means three independent caches and roughly a third of the hit rate for the same
traffic.

## Resource cost

```promql
sum by (pod) (rate(container_cpu_usage_seconds_total{namespace="kyverno"}[1m]))
sum by (pod) (container_memory_working_set_bytes{namespace="kyverno"})

# background scan cost (P17) -- reports controller, a separate registry egress path
sum(rate(container_cpu_usage_seconds_total{namespace="kyverno",pod=~".*reports-controller.*"}[5m]))
```

## Saturation signals

```promql
# API server waiting on webhooks
histogram_quantile(0.99, sum by (le) (
  rate(apiserver_request_duration_seconds_bucket{resource="pods",verb="POST"}[1m])))

# Kyverno's own queues backing up
sum by (controller) (rate(kyverno_controller_requeue_total[1m]))
sum by (controller) (rate(kyverno_controller_drop_total[1m]))

# admission report back-pressure (default threshold 1000 in flight)
sum(rate(kyverno_breaker_drops_total[1m]))
```

`kyverno_breaker_drops_total` going non-zero means Kyverno has stopped writing admission
reports to protect itself. Admission still works; your audit trail has holes. At fleet scale
this is the number that says "you need reports-server".

## Recording rules worth adding for a soak (P20)

```yaml
groups:
  - name: ivpol
    interval: 30s
    rules:
      - record: ivpol:webhook_latency:p99
        expr: histogram_quantile(0.99, sum by (le, name) (
                rate(apiserver_admission_webhook_admission_duration_seconds_bucket{name=~"ivpol\\..*"}[5m])))
      - record: ivpol:results:rate
        expr: sum by (policy_name, result) (rate(kyverno_image_validating_policy_results[5m]))
      - record: ivpol:registry_queries:rate
        expr: rate(kyverno_client_queries[5m])
```
