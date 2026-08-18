#!/usr/bin/env bash
# Snapshot the metrics that matter for IVP performance, and diff two snapshots.
#
#   bash 50-perf/collect.sh snap before
#   ... run the load ...
#   bash 50-perf/collect.sh snap after
#   bash 50-perf/collect.sh diff before after
#
# Uses Prometheus if PROM_URL is set; otherwise scrapes /metrics directly from the API server
# and the Kyverno pods, which works on any cluster and is why this exists rather than a
# Grafana dashboard.
set -euo pipefail

NS="${KYVERNO_NAMESPACE:-kyverno}"
DIR="$(cd "$(dirname "$0")" && pwd)/snaps"; mkdir -p "$DIR"
CMD="${1:?usage: collect.sh snap <name> | diff <a> <b>}"

snap() {
  local name="${1:?name}" d="$DIR/$name"; mkdir -p "$d"
  date -u +%FT%TZ > "$d/ts"

  # API server view -- the authoritative per-webhook latency. This is what actually delays a
  # kubectl apply, and it includes queueing that Kyverno's own metric cannot see.
  kubectl get --raw /metrics 2>/dev/null \
    | grep -E '^apiserver_admission_webhook_(admission_duration_seconds|rejection_count)|^apiserver_admission_controller_admission_duration_seconds' \
    > "$d/apiserver.prom" || echo "  (could not read apiserver /metrics -- needs RBAC on the metrics endpoint)" >&2

  # Kyverno's view -- attributes time to a specific policy and result.
  : > "$d/kyverno.prom"
  for p in $(kubectl -n "$NS" get pods -l app.kubernetes.io/component=admission-controller -o name 2>/dev/null); do
    kubectl -n "$NS" exec "${p#pod/}" -c kyverno -- \
      wget -qO- http://127.0.0.1:8000/metrics 2>/dev/null \
      | grep -E '^kyverno_(image_validating_policy_(execution_duration_seconds|results)|admission_(review_duration_seconds|requests)|client_queries|policy_results)' \
      >> "$d/kyverno.prom" || true
  done

  # Resource usage. metrics-server may not be installed; not fatal.
  kubectl -n "$NS" top pods --no-headers 2>/dev/null > "$d/top" || true

  # Replica count -- the cache is per-pod, so this changes the hit rate and must be recorded
  # alongside every latency number.
  kubectl -n "$NS" get deploy -o custom-columns=NAME:.metadata.name,READY:.status.readyReplicas --no-headers > "$d/replicas" 2>/dev/null || true

  # Policy + exception inventory: both are inputs to P7 and P8 and both drift between runs.
  kubectl get ivpol,nivpol -A --no-headers 2>/dev/null | wc -l > "$d/npolicies"
  kubectl get polex -A --no-headers 2>/dev/null | wc -l > "$d/nexceptions"

  # Cache configuration. NOT derivable after the fact -- record it or the run is unquotable.
  kubectl -n "$NS" get deploy -l app.kubernetes.io/component=admission-controller \
    -o jsonpath='{.items[0].spec.template.spec.containers[0].args}' 2>/dev/null \
    | tr ',' '\n' | grep -iE 'imageverifycache|registrycredential' > "$d/cacheflags" || true

  echo "snapshot '$name' written to $d"
}

diffsnap() {
  local a="$DIR/${1:?a}" b="$DIR/${2:?b}"
  python3 - "$a" "$b" <<'PY'
import sys, re, os, math
a, b = sys.argv[1], sys.argv[2]

def parse(path):
    m = {}
    if not os.path.exists(path): return m
    for line in open(path):
        line = line.strip()
        if not line or line.startswith('#'): continue
        try:
            key, val = line.rsplit(' ', 1)
            m[key] = m.get(key, 0.0) + float(val)
        except ValueError:
            pass
    return m

def hist(m, prefix, labelfilter=None):
    """Rebuild a histogram from _bucket series and return quantiles over the DELTA."""
    buckets = {}
    for k, v in m.items():
        if not k.startswith(prefix + '_bucket'): continue
        if labelfilter and labelfilter not in k: continue
        le = re.search(r'le="([^"]+)"', k)
        if not le: continue
        x = float('inf') if le.group(1) == '+Inf' else float(le.group(1))
        buckets[x] = buckets.get(x, 0.0) + v
    return buckets

def quantiles(before, after, qs=(0.5, 0.95, 0.99)):
    ks = sorted(set(before) | set(after))
    delta = [(k, after.get(k, 0) - before.get(k, 0)) for k in ks]
    total = delta[-1][1] if delta else 0
    if total <= 0: return None
    out = {}
    for q in qs:
        target = total * q
        for k, c in delta:
            if c >= target:
                out[q] = k
                break
    return out, total

for label, prefix, filt in [
    ("apiserver -> ivpol.validate", "apiserver_admission_webhook_admission_duration_seconds", 'name="ivpol.validate.kyverno.svc"'),
    ("apiserver -> ivpol.mutate",   "apiserver_admission_webhook_admission_duration_seconds", 'name="ivpol.mutate.kyverno.svc"'),
    ("kyverno ivpol execution",     "kyverno_image_validating_policy_execution_duration_seconds", None),
    ("kyverno admission review",    "kyverno_admission_review_duration_seconds", None),
]:
    src = "apiserver.prom" if "apiserver" in label else "kyverno.prom"
    r = quantiles(hist(parse(f"{a}/{src}"), prefix, filt), hist(parse(f"{b}/{src}"), prefix, filt))
    if not r:
        print(f"{label:32s} no samples in window")
        continue
    q, n = r
    print(f"{label:32s} n={int(n):6d}  p50={q.get(0.5,0)*1000:8.0f}ms  p95={q.get(0.95,0)*1000:8.0f}ms  p99={q.get(0.99,0)*1000:8.0f}ms")

# Counters
ba, bb = parse(f"{a}/kyverno.prom"), parse(f"{b}/kyverno.prom")
print()
for k in sorted(set(bb) | set(ba)):
    if 'image_validating_policy_results' in k or 'client_queries' in k:
        d = bb.get(k, 0) - ba.get(k, 0)
        if d > 0:
            print(f"  +{int(d):8d}  {k[:120]}")

aa, ab = parse(f"{a}/apiserver.prom"), parse(f"{b}/apiserver.prom")
for k in sorted(set(ab) | set(aa)):
    if 'rejection_count' in k and 'ivpol' in k:
        d = ab.get(k, 0) - aa.get(k, 0)
        if d > 0: print(f"  +{int(d):8d}  {k[:120]}")

print()
for f, name in [("replicas", "replicas"), ("npolicies", "IVPs"), ("nexceptions", "exceptions")]:
    for s, tag in ((a, "before"), (b, "after")):
        p = os.path.join(s, f)
        if os.path.exists(p):
            print(f"  {name:12s} {tag:6s} {open(p).read().strip()}")
for s, tag in ((a, "before"), (b, "after")):
    p = os.path.join(s, "cacheflags")
    if os.path.exists(p) and open(p).read().strip():
        print(f"  cacheflags   {tag:6s} {open(p).read().strip().replace(chr(10), ' ')}")
PY
}

case "$CMD" in
  snap) shift; snap "$@" ;;
  diff) shift; diffsnap "$@" ;;
  *) echo "usage: collect.sh snap <name> | diff <a> <b>" >&2; exit 1 ;;
esac
