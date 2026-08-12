#!/usr/bin/env bash
# Check X.509 certificates against the Notary Project certificate profile.
#
#   ./check-notary-profile.sh leaf.chain
#   ./check-notary-profile.sh leaf.crt intermediate.crt root.crt
#
# Accepts PEM bundles or individual files, in any combination. Each certificate is classified as
# CA or leaf from its basicConstraints and checked against the rules for that tier.
#
# Exit 0 = every certificate conforms. Exit 1 = at least one FAIL.
#
# WHY THIS EXISTS
# Notation validates the certificate profile at SIGNING time, not just at verification time, so a
# non-conforming certificate can't sign at all — you get
#   "certificate chain is invalid, certificate with subject ...: key usage extension must be
#    marked critical"
# which names one certificate even when several are wrong. This checks all of them at once and
# tells you exactly which requirement each one missed, so a single message to the PKI team covers
# everything instead of discovering the next defect after each re-issue.
#
# Source: Notary Project signature specification, "Certificate Requirements"
# https://github.com/notaryproject/specifications/blob/main/specs/signature-specification.md#certificate-requirements
set -uo pipefail

[ $# -ge 1 ] || { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
command -v openssl >/dev/null 2>&1 || { echo "openssl not found on PATH" >&2; exit 2; }

c_pass=$'\033[32m'; c_fail=$'\033[31m'; c_warn=$'\033[33m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
FAILED=0
pass() { echo "   ${c_pass}PASS${c_off}  $*"; }
fail() { echo "   ${c_fail}FAIL${c_off}  $*"; FAILED=1; }
note() { echo "   ${c_dim}·${c_off}     $*"; }

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# Split every input into individual certificates, preserving order.
n=0
for src in "$@"; do
  [ -f "$src" ] || { echo "no such file: $src" >&2; exit 2; }
  awk -v dir="$WORK" -v start="$n" '
    /-----BEGIN CERTIFICATE-----/ {inc=1; f=sprintf("%s/cert-%03d.pem", dir, start+c); c++}
    inc {print > f}
    /-----END CERTIFICATE-----/ {inc=0}
    END {exit}
  ' "$src"
  n=$(ls "$WORK" | wc -l | tr -d ' ')
done
[ "$n" -gt 0 ] || { echo "no PEM certificates found in: $*" >&2; exit 2; }

# Is this extension present, and is it marked critical?
#   returns: "absent" | "present" | "critical"
ext_state() {
  local text="$1" name="$2" line
  line="$(printf '%s\n' "$text" | grep -m1 "X509v3 ${name}:")" || true
  [ -n "$line" ] || { echo absent; return; }
  case "$line" in *critical*) echo critical ;; *) echo present ;; esac
}

# The human-readable value openssl prints on the line(s) after the extension header.
ext_value() {
  printf '%s\n' "$1" | grep -A1 -m1 "X509v3 ${2}:" | tail -n +2 | sed 's/^ *//' | tr -d '\n'
}

echo "Checking ${n} certificate(s) against the Notary Project profile"
echo

i=0
for f in "$WORK"/cert-*.pem; do
  i=$((i+1))
  text="$(openssl x509 -in "$f" -noout -text 2>/dev/null)" || { echo "[$i] not a valid certificate"; FAILED=1; continue; }
  subject="$(openssl x509 -in "$f" -noout -subject | sed 's/^subject=//')"
  bc_state="$(ext_state "$text" "Basic Constraints")"
  bc_value="$(ext_value "$text" "Basic Constraints")"
  ku_state="$(ext_state "$text" "Key Usage")"
  ku_value="$(ext_value "$text" "Key Usage")"
  eku_state="$(ext_state "$text" "Extended Key Usage")"
  eku_value="$(ext_value "$text" "Extended Key Usage")"
  sigalg="$(printf '%s\n' "$text" | grep -m1 'Signature Algorithm' | sed 's/.*: *//')"

  case "$bc_value" in *CA:TRUE*) tier="CA" ;; *) tier="leaf" ;; esac

  echo "[$i] ${tier}: ${subject}"

  # ---- applies to EVERY tier -------------------------------------------------
  # This is the requirement the error message is about, and it is identical for
  # root, intermediate and leaf.
  case "$ku_state" in
    critical) pass "keyUsage present and critical" ;;
    present)  fail "keyUsage present but NOT critical  <-- MUST be critical" ;;
    absent)   fail "keyUsage extension missing        <-- MUST be present and critical" ;;
  esac

  case "$sigalg" in
    *sha1*|*SHA1*|*sha1WithRSA*|*ecdsa-with-SHA1*) fail "signature algorithm is SHA-1 ($sigalg)" ;;
    *) pass "signature algorithm: $sigalg" ;;
  esac

  if [ "$tier" = "CA" ]; then
    # ---- root / intermediate -------------------------------------------------
    [ "$bc_state" = "critical" ] \
      && pass "basicConstraints critical, CA:TRUE" \
      || fail "basicConstraints must be present AND critical (is: $bc_state)"

    case "$ku_value" in
      *"Certificate Sign"*) pass "keyUsage contains keyCertSign" ;;
      *) fail "CA keyUsage must contain keyCertSign (is: ${ku_value:-none})" ;;
    esac
    note "cRLSign is permitted on a CA certificate"
  else
    # ---- leaf ----------------------------------------------------------------
    case "$bc_state" in
      absent) pass "basicConstraints absent (permitted on a leaf)" ;;
      *)      case "$bc_value" in
                *CA:FALSE*) pass "basicConstraints CA:FALSE" ;;
                *)          fail "leaf basicConstraints must be CA:FALSE (is: $bc_value)" ;;
              esac ;;
    esac

    case "$ku_value" in
      *"Digital Signature"*) pass "keyUsage contains digitalSignature" ;;
      *) fail "leaf keyUsage must contain digitalSignature (is: ${ku_value:-none})" ;;
    esac

    # On a leaf these bits are forbidden outright — not merely unnecessary.
    forbidden=""
    for bad in "Certificate Sign" "CRL Sign" "Key Encipherment" "Data Encipherment" \
               "Key Agreement" "Encipher Only" "Decipher Only"; do
      case "$ku_value" in *"$bad"*) forbidden="${forbidden}${bad}, " ;; esac
    done
    [ -z "$forbidden" ] \
      && pass "no forbidden keyUsage bits" \
      || fail "leaf keyUsage has forbidden bits: ${forbidden%, }"

    if [ "$eku_state" = "absent" ]; then
      pass "extendedKeyUsage absent (permitted)"
    else
      badeku=""
      for bad in "TLS Web Server Authentication" "TLS Web Client Authentication" \
                 "E-mail Protection" "Time Stamping" "Any Extended Key Usage"; do
        case "$eku_value" in *"$bad"*) badeku="${badeku}${bad}, " ;; esac
      done
      [ -z "$badeku" ] \
        && pass "extendedKeyUsage OK: ${eku_value}" \
        || fail "forbidden extendedKeyUsage: ${badeku%, }"
    fi

    # Key length — RSA >= 2048, EC >= 256.
    keyinfo="$(printf '%s\n' "$text" | grep -m1 'Public-Key:' | tr -d ' ' | sed 's/.*(\([0-9]*\)bit.*/\1/')"
    keytype="$(printf '%s\n' "$text" | grep -m1 'Public Key Algorithm' | sed 's/.*: *//')"
    case "$keytype" in
      *rsa*|*RSA*) [ "${keyinfo:-0}" -ge 2048 ] && pass "RSA ${keyinfo} bits" || fail "RSA key must be >= 2048 bits (is ${keyinfo})" ;;
      *ecPublicKey*|*EC*|*id-ecPublicKey*) [ "${keyinfo:-0}" -ge 256 ] && pass "EC ${keyinfo} bits" || fail "EC key must be >= 256 bits (is ${keyinfo})" ;;
      *) note "unrecognised key type: $keytype" ;;
    esac
  fi
  echo
done

if [ "$FAILED" -eq 0 ]; then
  echo "${c_pass}All certificates conform to the Notary Project profile.${c_off}"
else
  cat <<EOF
${c_fail}At least one certificate does not conform.${c_off}

${c_warn}Note:${c_off} extension criticality and contents are decided by the ISSUING CA's certificate
template, not by Venafi. Re-enrolling against an unchanged template reproduces the same defect —
the template has to be fixed first. See README.md section 2.9 for the request to send.
EOF
fi
exit "$FAILED"
