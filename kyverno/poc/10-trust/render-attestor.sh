#!/usr/bin/env bash
# Inline a PEM trust anchor into the notary attestor block of every policy in 20-policies/,
# with correct YAML indentation.
#
#   bash 10-trust/render-attestor.sh <ca.crt> [--in-place]
#
# Without --in-place, prints the rendered attestor block to stdout so you can eyeball it.
# With --in-place, rewrites REPLACE_WITH_ROOT_CA_PEM in 20-policies/*.yaml.
#
# WHY A SCRIPT: a PEM pasted into a YAML block scalar at the wrong indent produces a policy
# that either fails to apply with an unhelpful parser error, or -- worse -- applies with a
# truncated cert and then fails every verification at admission with a chain error that looks
# like a signing problem. This has cost people days.
set -euo pipefail

CA="${1:?usage: render-attestor.sh <ca.crt> [--in-place]}"
MODE="${2:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"

[ -f "$CA" ] || { echo "not found: $CA" >&2; exit 1; }

# ---- sanity-check the anchor before it goes anywhere --------------------------
openssl x509 -in "$CA" -noout >/dev/null 2>&1 || { echo "not a PEM certificate: $CA" >&2; exit 1; }

COUNT=$(grep -c 'BEGIN CERTIFICATE' "$CA" || true)
SUBJ=$(openssl x509 -in "$CA" -noout -subject | sed 's/^subject= *//')
ISS=$(openssl x509 -in "$CA" -noout -issuer  | sed 's/^issuer= *//')
END=$(openssl x509 -in "$CA" -noout -enddate | cut -d= -f2)

echo "# anchor: $SUBJ" >&2
echo "# issuer: $ISS"  >&2
echo "# expires: $END" >&2
echo "# certificates in file: $COUNT" >&2

if [ "$SUBJ" != "$ISS" ]; then
  echo >&2
  echo "WARNING: this certificate is NOT self-signed -- it looks like an intermediate." >&2
  echo "  ADR-0003 rejected pinning an intermediate as the trust anchor: the Notary spec" >&2
  echo "  advises against it because rotating the intermediate breaks verification for" >&2
  echo "  everything already signed. Use the ROOT (trust/ca.crt)." >&2
  echo >&2
fi

if ! openssl x509 -in "$CA" -noout -checkend 0 >/dev/null 2>&1; then
  echo "ERROR: anchor has EXPIRED ($END). Nothing will verify." >&2
  exit 1
fi

# ---- render ------------------------------------------------------------------
# 12 spaces matches `        certs:\n          value: |\n            <pem>` in the policies.
BLOCK=$(sed 's/^/            /' "$CA")

if [ "$MODE" = "--in-place" ]; then
  python3 - "$HERE/../20-policies" "$CA" <<'PY'
import sys, pathlib
d, ca = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]).read_text().rstrip("\n")
block = "\n".join("            " + l for l in ca.splitlines())
# The placeholder sits inside a `value: |` block already indented to 12; replace the whole
# three-line stub (BEGIN / placeholder / END) with the real PEM.
stub = ("            -----BEGIN CERTIFICATE-----\n"
        "            REPLACE_WITH_ROOT_CA_PEM\n"
        "            -----END CERTIFICATE-----")
n = 0
for f in sorted(d.glob("*.yaml")):
    t = f.read_text()
    if stub in t:
        f.write_text(t.replace(stub, block))
        n += 1
        print(f"  rewrote {f.name}", file=sys.stderr)
    elif "REPLACE_WITH_ROOT_CA_PEM" in t:
        print(f"  SKIPPED {f.name}: placeholder present but not at the expected indent", file=sys.stderr)
print(f"  {n} file(s) updated", file=sys.stderr)
PY
  echo >&2
  echo "Now confirm each policy still parses:" >&2
  echo "  kubectl apply --dry-run=server -f 20-policies/" >&2
else
  cat <<EOF
      attestors:
        - name: notary
          notary:
            certs:
              value: |
$BLOCK
EOF
fi
