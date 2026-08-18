#!/usr/bin/env bash
# Pod-creation load generator with client-side latency measurement.
#
#   bash 50-perf/loadgen.sh -i <image> -n <count> -c <concurrency> [-N ns] [-C containers] [-d]
#
#   -i  image reference (repeat -i for a multi-image pod; see -C)
#   -n  total pods            (default 100)
#   -c  concurrency           (default 10)
#   -N  namespace             (default ivpol-perf)
#   -C  containers per pod    (default 1) -- distinct images, appended with a unique suffix
#   -d  dry-run (server-side): exercises the FULL admission chain including webhooks but
#       writes nothing to etcd. This is the right mode for latency work -- it isolates webhook
#       cost from scheduler and kubelet noise, and leaves no pods to clean up.
#
# Writes a CSV of per-request wall-clock latency to $OUT (default 50-perf/out/<ts>.csv).
#
# WHY CLIENT-SIDE TIMING AS WELL AS METRICS: apiserver_admission_webhook_admission_duration
# is the authoritative per-webhook number, but it does not include the API server's own
# serialization, the second webhook's queueing behind the first, or anything the Wiz webhook
# adds. The client-side distribution is what a `kubectl apply` actually feels like, which is
# the number the platform team will be asked about.
set -euo pipefail

IMAGES=(); COUNT=100; CONC=10; NS=ivpol-perf; NCONT=1; DRY=""
while getopts "i:n:c:N:C:d" o; do case $o in
  i) IMAGES+=("$OPTARG") ;; n) COUNT=$OPTARG ;; c) CONC=$OPTARG ;;
  N) NS=$OPTARG ;; C) NCONT=$OPTARG ;; d) DRY="--dry-run=server" ;;
esac; done
[ ${#IMAGES[@]} -gt 0 ] || { echo "need at least one -i <image>" >&2; exit 1; }

TS=$(date +%Y%m%d-%H%M%S)
OUTDIR="$(cd "$(dirname "$0")" && pwd)/out"; mkdir -p "$OUTDIR"
OUT="${OUT:-$OUTDIR/$TS.csv}"

kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create ns "$NS" >/dev/null

echo "idx,start_ns,latency_ms,exit,verdict" > "$OUT"

mkpod() {
  local i=$1 name="perf-$TS-$1"
  {
    echo "apiVersion: v1"
    echo "kind: Pod"
    echo "metadata:"
    echo "  name: $name"
    echo "  namespace: $NS"
    echo "  labels: { app: ivpol-perf, run: \"$TS\" }"
    echo "spec:"
    echo "  restartPolicy: Never"
    echo "  containers:"
    for c in $(seq 1 "$NCONT"); do
      # Round-robin the supplied images. With -C > 1 and a single -i, every container gets the
      # same image -- which measures per-POD cost with a warm per-image cache. Supply -C
      # distinct images to measure true per-IMAGE fan-out (P6).
      local img="${IMAGES[$(( (c - 1) % ${#IMAGES[@]} ))]}"
      echo "  - name: c$c"
      echo "    image: $img"
      echo "    command: ['sleep','3600']"
    done
  }
}

one() {
  local i=$1 s e rc out verdict
  s=$(date +%s%N)
  out=$(mkpod "$i" | kubectl apply $DRY -f - 2>&1); rc=$?
  e=$(date +%s%N)
  if [ $rc -eq 0 ]; then verdict=admitted
  elif echo "$out" | grep -qi 'denied the request\|admission webhook'; then verdict=denied
  elif echo "$out" | grep -qi 'timeout\|context deadline'; then verdict=timeout
  else verdict=error; fi
  printf '%s,%s,%s,%s,%s\n' "$i" "$s" "$(( (e - s) / 1000000 ))" "$rc" "$verdict" >> "$OUT"
}
export -f one mkpod; export NS DRY TS OUT NCONT
export IMAGES_JOINED="${IMAGES[*]}"

echo "run $TS: $COUNT pods, concurrency $CONC, $NCONT container(s), ns=$NS ${DRY:+(server dry-run)}"
START=$(date +%s)
seq 1 "$COUNT" | xargs -P "$CONC" -I{} bash -c 'one {}'
END=$(date +%s)

python3 - "$OUT" "$START" "$END" <<'PY'
import csv, sys, statistics as st
rows = list(csv.DictReader(open(sys.argv[1])))
lat  = sorted(float(r["latency_ms"]) for r in rows)
dur  = max(1, int(sys.argv[3]) - int(sys.argv[2]))
def q(p): return lat[min(len(lat)-1, int(len(lat)*p))] if lat else 0
v = {}
for r in rows: v[r["verdict"]] = v.get(r["verdict"], 0) + 1
print(f"\n  n={len(lat)}  wall={dur}s  throughput={len(lat)/dur:.1f}/s")
print(f"  p50={q(.50):.0f}ms  p95={q(.95):.0f}ms  p99={q(.99):.0f}ms  max={lat[-1]:.0f}ms  mean={st.mean(lat):.0f}ms")
print("  verdicts: " + "  ".join(f"{k}={n}" for k, n in sorted(v.items())))
print(f"\n  csv: {sys.argv[1]}")
if v.get("timeout"): print("\n  TIMEOUTS PRESENT -- with failurePolicy: Fail these would be hard denials.")
PY

echo
echo "Cleanup:  kubectl -n $NS delete pods -l run=$TS"
echo "Metrics:  bash 50-perf/collect.sh   (run it before and after for a clean diff)"
