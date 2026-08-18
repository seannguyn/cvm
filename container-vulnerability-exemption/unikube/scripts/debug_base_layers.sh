#!/usr/bin/env bash
# Debug the "base layers" rule in compliance_check.py.
#
#   ./debug_base_layers.sh <built-image> <base-ref>
#
# e.g. ./debug_base_layers.sh wiz-poc:2.0 container-soe.docker.internal.cba/alpine:3.23
#
# The rule is: the base's RootFS.Layers (diff_ids) must be the PREFIX of the built
# image's. This script shows you exactly where that breaks and, if it does, which
# base tag your image was ACTUALLY built on.
 
set -uo pipefail
 
IMG="${1:?usage: $0 <built-image> <base-ref>}"
BASE="${2:?usage: $0 <built-image> <base-ref>}"
# candidate tags to test if the given base doesn't match (edit to taste)
CANDIDATES="${CANDIDATES:-3.23 3.22 3.21 3.20 3.19}"
 
BASE_REPO="${BASE%:*}"
 
echo "=============================================================="
echo " 0. platform — compare like for like"
echo "=============================================================="
IMG_PLAT=$(docker inspect --format '{{.Os}}/{{.Architecture}}' "$IMG") || exit 1
echo "built image platform: $IMG_PLAT"
export DOCKER_DEFAULT_PLATFORM="$IMG_PLAT"
echo "DOCKER_DEFAULT_PLATFORM set to $IMG_PLAT for the pulls below"
echo
 
echo "=============================================================="
echo " 1. identity of both images"
echo "=============================================================="
docker pull -q "$BASE" >/dev/null 2>&1
for r in "$IMG" "$BASE"; do
  echo "-- $r"
  docker inspect --format '   created:     {{.Created}}
   platform:    {{.Os}}/{{.Architecture}}
   repodigests: {{.RepoDigests}}
   base.name:   {{index .Config.Labels "org.opencontainers.image.base.name"}}
   base.digest: {{index .Config.Labels "org.opencontainers.image.base.digest"}}' "$r"
done
echo
echo "NOTE: empty base.digest on the built image => compliance_check.py cannot pin,"
echo "      falls back to the tag as served now, and a republished base breaks you."
echo "NOTE: empty repodigests on the built image => this local tag was never pushed"
echo "      or pulled; you may be checking a stale local build."
echo
 
echo "=============================================================="
echo " 2. where does the layer prefix break?"
echo "=============================================================="
python3 - "$IMG" "$BASE" <<'PY'
import json, subprocess, sys
 
def layers(ref):
    p = subprocess.run(["docker", "inspect", "--format", "{{json .RootFS.Layers}}", ref],
                       capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"docker inspect {ref} failed: {p.stderr.strip()}")
    return json.loads(p.stdout)
 
img_ref, base_ref = sys.argv[1], sys.argv[2]
img, base = layers(img_ref), layers(base_ref)
print(f"  built image : {len(img)} layer(s)")
print(f"  base        : {len(base)} layer(s)")
print()
 
n = min(len(img), len(base))
bad = next((k for k in range(n) if img[k] != base[k]), None)
for k in range(n):
    same = img[k] == base[k]
    print(f"  {'ok' if same else 'XX'}  [{k}]  built={img[k][7:19]}...  base={base[k][7:19]}...")
print()
 
if len(base) > len(img):
    print("  VERDICT: the base has MORE layers than the built image — this cannot be its base.")
elif bad is None:
    print("  VERDICT: prefix MATCHES. The layer rule would PASS against this base ref.")
elif bad == 0:
    print("  VERDICT: diverges at layer 0 — the two images share nothing.")
    print("           Either a different base entirely, or the tag was republished with")
    print("           a rebuilt bottom layer. Step 3 finds which.")
else:
    print(f"  VERDICT: shares {bad} layer(s), then diverges at layer {bad}.")
    print("           Classic patched/republished base: same lineage, new content.")
PY
echo
 
echo "=============================================================="
echo " 3. which base tag does the built image ACTUALLY sit on?"
echo "=============================================================="
IMG_L0=$(docker inspect --format '{{index .RootFS.Layers 0}}' "$IMG")
echo "built image layer[0] = $IMG_L0"
echo
for t in $CANDIDATES; do
  ref="${BASE_REPO}:${t}"
  if docker pull -q "$ref" >/dev/null 2>&1; then
    l0=$(docker inspect --format '{{index .RootFS.Layers 0}}' "$ref")
    [ "$l0" = "$IMG_L0" ] && mark="<<< MATCH — built on this one" || mark=""
    printf '  %-12s layer[0] = %s %s\n' "$t" "$l0" "$mark"
  else
    printf '  %-12s (not served)\n' "$t"
  fi
done
echo
echo "If NOTHING matches, the current tags no longer serve the content your image was"
echo "built on (republished, and the old digest may be gone). Rebuild against the base"
echo "as served now, and record the digest so this stops recurring:"
echo
echo "  export DOCKER_DEFAULT_PLATFORM=$IMG_PLAT"
echo "  docker pull $BASE"
echo "  D=\$(docker inspect --format '{{index .RepoDigests 0}}' $BASE | cut -d@ -f2)"
echo "  docker build --label org.opencontainers.image.base.digest=\$D -t <img>:<tag> ."
 