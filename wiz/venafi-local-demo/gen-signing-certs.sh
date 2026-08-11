#!/usr/bin/env bash
# Generate a TEST signing PKI for the Notation tutorial in README.md:
#
#     root CA (10y)  ->  intermediate CA (5y)  ->  signing leaf (365d)
#     ^ the trust anchor: this is the certificate a verifier is given
#
# Everything lands in ./pki/ next to this script. Self-contained: no system openssl.cnf
# required, works with both OpenSSL and the LibreSSL that ships as /usr/bin/openssl on macOS.
#
# USAGE
#   ./gen-signing-certs.sh [LEAF_DAYS]            # build the whole PKI (default 365)
#   ./gen-signing-certs.sh --reissue-leaf [DAYS]  # keep root+intermediate, new leaf only
#   ./gen-signing-certs.sh --second-leaf [DAYS]   # a SECOND leaf, different team (OU=Other-Team)
#   ./gen-signing-certs.sh ... --allow-short      # accept a leaf clamped by its issuer
#
# --second-leaf exists to demonstrate the point below: it issues a leaf belonging to a different
# team from the SAME intermediate. Both leaves chain to the same root, so a verifier that can only
# check the trust anchor admits both. See README.md sections 1.6-1.7.
#
# ── WHY THREE TIERS ───────────────────────────────────────────────────────────────────────
# A verifier that only accepts "which CA do I trust?" — with no way to also pin *which
# certificate under that CA* is allowed — makes the trust anchor an unrestricted signing
# authority. Anything chaining to it is admitted. So the anchor must be a CA used for nothing
# else, and it must be STABLE: changing it invalidates every signature made under it. Day-to-day
# issuance therefore happens at the intermediate, which can rotate without touching the anchor
# and without invalidating anything already signed.
#
# ── THE CLAMP ─────────────────────────────────────────────────────────────────────────────
# Without trusted timestamping, verification requires EVERY certificate in the chain to be valid
# at verification time. So the real lifetime of a signature is:
#
#     min(leaf.notAfter, intermediate.notAfter, root.notAfter)
#
# Issuing a 365-day leaf from an intermediate with 200 days left produces a signature that dies
# in 200 days while the leaf still reads a year — a SILENT truncation. This script refuses to do
# that unless you pass --allow-short. The rule is recursive: it applies to the intermediate under
# the root exactly as to the leaf under the intermediate. The clamp only ever binds on re-issue,
# which is the annual rotation case it exists for.
#
# ── WHY NOT TIMESTAMP ─────────────────────────────────────────────────────────────────────
# Because certificate expiry is the only revocation mechanism available here, and it works
# precisely because an attacker cannot extend it. A trust-timestamped signature survives its
# certificate's expiry indefinitely, so a leaked key would stay usable forever instead of for at
# most one leaf lifetime. Keep the leaf short; do not timestamp.
#
# ── THIS IS TEST MATERIAL ─────────────────────────────────────────────────────────────────
# All three private keys are written to ./pki/ in the clear. In production the root and
# intermediate keys live in an HSM and never touch a filesystem, and the signing key is held by a
# code-signing service (see README.md, Option 2). Do not commit ./pki/ and do not reuse these
# certificates for anything real.
set -euo pipefail

ROOT_DAYS=3650          # 10y
INTERMEDIATE_DAYS=1825  # 5y
BUFFER_DAYS=30          # a child must expire this far before its issuer

MODE="full"
DAYS=""
ALLOW_SHORT=0
for arg in "$@"; do
  case "$arg" in
    --reissue-leaf) MODE="reissue" ;;
    --second-leaf)  MODE="second" ;;
    --allow-short)  ALLOW_SHORT=1 ;;
    -h|--help)      sed -n '2,50p' "$0"; exit 0 ;;
    ''|*[!0-9]*)    echo "unknown argument: $arg" >&2; exit 2 ;;
    *)              DAYS="$arg" ;;
  esac
done
DAYS="${DAYS:-365}"

OUT="$(cd "$(dirname "$0")" && pwd)/pki"
mkdir -p "$OUT"
cd "$OUT"

# The Notary certificate profile requires C, ST (or S) and O in the subject. OU is what scopes
# signing authority to a team. A verifier that supports identity pinning matches on these, and a
# leaf carrying only CN and O cannot be pinned by a valid policy — so issue a full DN even when
# the verifier you have today ignores it.
SUBJ_BASE="/C=US/ST=WA/O=ExampleOrg"
SUBJ_OU="OU=Platform-Unikube"

log() { echo ">> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

command -v openssl >/dev/null 2>&1 || die "openssl not found on PATH"

# Days remaining on a certificate. GNU and BSD `date` disagree on parsing, so try both.
remaining_days() {
  local end epoch now
  end="$(openssl x509 -in "$1" -noout -enddate | cut -d= -f2)"
  epoch="$(date -u -d "$end" +%s 2>/dev/null \
        || date -u -j -f "%b %d %H:%M:%S %Y %Z" "$end" +%s 2>/dev/null)" \
    || die "could not parse notAfter ('$end') from $1"
  now="$(date -u +%s)"
  echo $(( (epoch - now) / 86400 ))
}

# Longest child lifetime this issuer can support, or fail with the reason.
# Echoes the number of days; logs go to stderr so the value stays clean.
clamp_to_issuer() {
  local issuer="$1" requested="$2" what="$3"
  local remaining max
  remaining="$(remaining_days "$issuer")"
  max=$(( remaining - BUFFER_DAYS ))

  if [ "$remaining" -le 0 ]; then
    die "$issuer has EXPIRED ($remaining days) — nothing can be issued from it. Rotate it."
  fi
  if [ "$max" -le 0 ]; then
    die "$issuer expires in $remaining days, inside the ${BUFFER_DAYS}-day buffer.
     Rotate the issuer before issuing a new $what."
  fi
  if [ "$requested" -gt "$max" ]; then
    if [ "$ALLOW_SHORT" -eq 1 ]; then
      echo "WARNING: $what clamped from ${requested}d to ${max}d by its issuer" >&2
      echo "$max"
    else
      die "refusing to issue a ${requested}-day $what from an issuer with $remaining days left.
     It would be silently truncated to ${max}d — signatures would stop verifying then, while the
     certificate still claimed ${requested}d.
     Fix: rotate the issuer (preferred), or re-run with --allow-short to accept ${max}d."
    fi
  fi
  echo "${max}" | awk -v r="$requested" -v m="$max" 'BEGIN{print (r>m)?m:r}'
}

# A minimal, self-contained openssl config. The stock `openssl req -x509` wants a config file
# with a [req] section, and its location differs across distros and macOS — so ship our own
# rather than guessing at /etc/ssl/openssl.cnf, which does not exist on a Mac.
write_cnf() {
  cat > openssl.cnf <<'EOF'
[req]
distinguished_name = dn
prompt             = no

[dn]
CN = placeholder

# CA:TRUE with pathlen:1 — this root may issue an intermediate, which may not issue further CAs.
[v3_root]
basicConstraints     = critical,CA:TRUE,pathlen:1
keyUsage             = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
EOF

  # pathlen:0 — the intermediate may issue leaves, never another CA.
  cat > intermediate.ext <<'EOF'
basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
EOF

  # THE LEAF PROFILE. This is the shape a code-signing certificate must have, and the exact
  # thing to specify when asking a PKI team for one:
  #   CA:FALSE                 — a CA certificate is rejected as a signing certificate
  #   digitalSignature only    — keyCertSign/cRLSign MUST NOT be present on a leaf
  #   codeSigning EKU          — and NOT serverAuth/clientAuth/timeStamping/anyExtendedKeyUsage
  # A TLS server certificate fails this profile, which is why an ordinary web-server template
  # cannot be reused for image signing.
  cat > signing.ext <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=codeSigning
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid:always
EOF
}

# issue_leaf <file-prefix> <OU> <CN>
issue_leaf() {
  local prefix="$1" ou="$2" cn="$3" days
  days="$(clamp_to_issuer intermediate.crt "$DAYS" "leaf")"
  log "issuing leaf CN=$cn ($ou) for ${days} days (intermediate has $(remaining_days intermediate.crt) left)"
  openssl genrsa -out "${prefix}.key" 4096 2>/dev/null
  openssl req -new -key "${prefix}.key" -config openssl.cnf \
    -subj "$SUBJ_BASE/$ou/CN=$cn" -out "${prefix}.csr"
  openssl x509 -req -in "${prefix}.csr" -CA intermediate.crt -CAkey intermediate.key \
    -CAcreateserial -days "$days" -sha256 -extfile signing.ext -out "${prefix}.crt" 2>/dev/null

  # The Notary spec requires the signature envelope to carry the COMPLETE chain, from the signing
  # certificate up to the root. This concatenated file is what you sign with — a bare leaf signs
  # without complaint and then fails verification.
  cat "${prefix}.crt" intermediate.crt root.crt > "${prefix}-chain.crt"
}

write_cnf

if [ "$MODE" = "reissue" ]; then
  # The rotation case — and the only one where the clamp can actually bind, since the issuer
  # already exists and has been ageing.
  for f in root.crt intermediate.crt intermediate.key; do
    [ -f "$f" ] || die "--reissue-leaf needs an existing PKI; $OUT/$f is missing. Run without it first."
  done
  log "output dir: $OUT (re-issuing leaf only; root + intermediate untouched)"
  issue_leaf signing "$SUBJ_OU" "unikube-image-signer"

elif [ "$MODE" = "second" ]; then
  # A DIFFERENT TEAM's signing certificate, from the same intermediate and therefore the same
  # root. Nothing about this is a misconfiguration — it is what a shared CA is FOR. The point is
  # what it means downstream: both leaves chain to the same anchor, so a verifier whose only
  # control is "which CA do I trust?" cannot tell them apart and admits both.
  for f in root.crt intermediate.crt intermediate.key; do
    [ -f "$f" ] || die "--second-leaf needs an existing PKI; $OUT/$f is missing. Run without it first."
  done
  log "output dir: $OUT (issuing a SECOND leaf for a different team)"
  issue_leaf signing-team-b "OU=Other-Team" "other-team-signer"

else
  log "output dir: $OUT (building full PKI; leaf requested ${DAYS} days)"

  # ---- 1. Root CA — the trust anchor. Offline in production. -----------------
  openssl genrsa -out root.key 4096 2>/dev/null
  openssl req -x509 -new -nodes -key root.key -sha256 -days "$ROOT_DAYS" \
    -subj "$SUBJ_BASE/CN=ExampleOrg Container Signing Root CA" \
    -config openssl.cnf -extensions v3_root \
    -out root.crt

  # ---- 2. Intermediate CA — clamped to the root, same rule one tier up -------
  int_days="$(clamp_to_issuer root.crt "$INTERMEDIATE_DAYS" "intermediate")"
  openssl genrsa -out intermediate.key 4096 2>/dev/null
  openssl req -new -key intermediate.key -config openssl.cnf \
    -subj "$SUBJ_BASE/$SUBJ_OU/CN=ExampleOrg Image Signing CA" -out intermediate.csr
  openssl x509 -req -in intermediate.csr -CA root.crt -CAkey root.key -CAcreateserial \
    -days "$int_days" -sha256 -extfile intermediate.ext -out intermediate.crt 2>/dev/null

  # ---- 3. Signing leaf — clamped to the intermediate -------------------------
  issue_leaf signing "$SUBJ_OU" "unikube-image-signer"
fi

echo
log "verifying the chain builds..."
if [ "$MODE" = "second" ]; then
  openssl verify -CAfile root.crt -untrusted intermediate.crt signing-team-b.crt
else
  openssl verify -CAfile root.crt -untrusted intermediate.crt signing.crt
fi

# What actually governs signature lifetime: the earliest expiry in the chain, not the leaf's.
R=$(remaining_days root.crt); I=$(remaining_days intermediate.crt); L=$(remaining_days signing.crt)
EFFECTIVE=$R; TIER="root"
[ "$I" -lt "$EFFECTIVE" ] && { EFFECTIVE=$I; TIER="intermediate"; }
[ "$L" -lt "$EFFECTIVE" ] && { EFFECTIVE=$L; TIER="leaf"; }

if [ "$MODE" = "second" ]; then
cat <<EOF

>> SECOND LEAF ISSUED
   subject: $(openssl x509 -in signing-team-b.crt -noout -subject | sed 's/^subject=//')
   files:   signing-team-b.crt / .key / -chain.crt

   This leaf belongs to a different team and chains to the SAME root.crt. A verifier holding
   only root.crt will admit anything signed with it, exactly as it admits the first leaf —
   it has no way to ask "but is this the RIGHT signer?".

>> NEXT: README.md section 1.6 — sign a second image with it, then 1.7 to try pinning.
EOF
else
cat <<EOF

>> CHAIN LIFETIMES (days remaining)
   root         $R
   intermediate $I
   leaf         $L
   -> signatures made now stop verifying in $EFFECTIVE days, governed by the $TIER.

>> FILES in $OUT
   root.crt            the TRUST ANCHOR — give this to the verifier (never the intermediate)
   signing-chain.crt   leaf + intermediate + root — SIGN WITH THIS, not signing.crt
   signing.key         the private key, in the clear. This is the thing Option 2 gets rid of.

>> NEXT: README.md section 1.2 — register the key with notation.

>> Annual rotation (the case the clamp exists for):
   ./gen-signing-certs.sh --reissue-leaf

>> A second team's leaf under the same root (README.md 1.6):
   ./gen-signing-certs.sh --second-leaf
EOF
fi
