# Target signing workflow — Venafi TPP + CodeSign Protect

**Status: proposed design. Nothing in the repo has been changed by this document.**

Companion to [`venafi-pivot.md`](venafi-pivot.md) (which option and why) and
[`notation-signing.md`](notation-signing.md) (why the PKI is shaped this way). This one is the
*how*: the end-to-end workflow given the stack that actually exists — **self-hosted Venafi TPP**
plus [`Venafi/notation-venafi-csp`](https://github.com/Venafi/notation-venafi-csp).

> **Correction to `venafi-pivot.md` §2.1:** that section is written around Zero Touch PKI, the
> *SaaS* private-PKI service. The org's Control Plane SaaS is used for discovery only; issuance
> is self-hosted TPP. The relevant product is **CodeSign Protect**, a TPP module — and the
> plugin is native to it (`tpp_url` / `access_token` / `tpp_project`, badged for self-hosted
> 23.1+). The A-vs-B recommendation is unaffected.

---

## 1. The shape

```
┌─ PKI team ─────────────────────────────────────────────────────────┐
│  Container Signing Root CA        dedicated, HSM, offline          │
│    └─ Image Signing CA            HSM                              │
└────────────────────────────────────────────────────────────────────┘
                │ issues into
┌─ TPP / CodeSign Protect ───────────────────────────────────────────┐
│  Project: container-image-signing                                  │
│    Environment: unikube-image-signer                               │
│      key   RSA-3072, generated in HSM, NON-EXPORTABLE              │
│      cert  leaf 365d + full chain                                  │
│      Key Use Approver: pre-approved for the CI identity            │
└────────────────────────────────────────────────────────────────────┘
                │ signs remotely (key never leaves)
┌─ CI (unikube.yaml) ────────────────────────────────────────────────┐
│  build → scan → compliance check → push → notation sign --plugin   │
└────────────────────────────────────────────────────────────────────┘
                │ signature as OCI referrer
┌─ Wiz ──────────────────────────────────────────────────────────────┐
│  image_integrity_validator: certificate = trust/ca.crt (the root)  │
└────────────────────────────────────────────────────────────────────┘
```

**The property that must hold end to end:** the only key that can produce a signature chaining to
`trust/ca.crt` lives in the TPP HSM, and only the CI identity may invoke it. Wiz has no
signer-identity check ([`notation-signing.md` §3](notation-signing.md)), so this is enforced by
custody, not policy.

---

## 2. Phase 1 — the PKI (PKI team)

Same three tiers as today; the only change is where the keys live.

| Tier | Validity | Custody | Goes where |
|---|---|---|---|
| Container Signing Root CA | 10y | HSM, offline | `trust/ca.crt` → Wiz |
| Image Signing CA | 5y | HSM | travels in the chain |
| `unikube-image-signer` leaf | 365d | **TPP CodeSign Protect HSM** | signs; never leaves |

Specify explicitly, because the defaults will be wrong:

- **Leaf profile.** `basicConstraints CA:FALSE`; `keyUsage digitalSignature` **only** (no
  `keyCertSign`/`cRLSign`); EKU `codeSigning`, and **not** `serverAuth`, `clientAuth`,
  `timeStamping`, or `anyExtendedKeyUsage`. TPP issuing templates are TLS-shaped by default and
  will hand you `serverAuth` unless told otherwise — which fails Notary verification.
- **Full DN** on the leaf: `C`, `ST`, `O`, `OU=Platform-Unikube`. Wiz cannot use it today, but it
  is the prerequisite for `trustedIdentities` if Wiz ever gains pinning, or if enforcement moves
  to Kyverno.
- **365-day leaf.** Push back on shorter. With no timestamping, leaf lifetime *is* image
  admissibility — a 90-day leaf means re-signing everything quarterly.
- **The clamp.** A child must never outlive its issuer minus a buffer, or images die silently
  early while the certificate still reads a full year
  ([`notation-signing.md` §5](notation-signing.md)). Ask whether the TPP template enforces this.
  **Assume it does not** and keep an equivalent check in CI (see §4).
- **CDP/AIA**, if the CA can host CRL/OCSP. This is the one real advantage the org root had; on a
  dedicated root it costs nothing to ask for and closes the revocation gap.

---

## 3. Phase 2 — CodeSign Protect (TPP admin + security)

CodeSign Protect organises signing as **Projects** containing **Environments** — an environment
being the container for a key and its certificate, configurable to generate a new key or adopt an
existing one. Roles are assigned per project on the Users & Approvers page.

**Project:** `container-image-signing` · **Environment:** `unikube-image-signer`

| Setting | Value | Why |
|---|---|---|
| Key generation | **generate in HSM**, non-exportable | the entire point; no PEM ever exists |
| Key spec | RSA-3072 (or EC-384) | both in the plugin's supported set |
| Certificate | leaf + **full chain** stored on the environment | the envelope must carry leaf → intermediate → root |
| Key Use Approver | **pre-approves** the CI identity | see below |
| Key Administrator | PKI/security — *not* the platform team | separation of duties |
| **Timestamp service** | **OFF** | ⚠ see below |
| Audit | retained, exported to SIEM | this is what replaces "a human reviewed the PR" |

**Pre-approval, not interactive approval.** CodeSign Protect's default is a human approving each
key use, and only the Key Use Approver role can *pre-approve*. A per-build human gate would
invert the "compliant image is admitted with no PR" model in `new_direction_PLAN.md`. So: the Key
Use Approver pre-approves key use for the pipeline's service identity, and the **audit record is
the compensating control**. That trade should be written down and signed off, not assumed.

**⚠ Leave the timestamp service off.** TPP hosts a Code Signing Timestamp Service and enabling it
is normally best practice. Here it would destroy our only revocation mechanism: certificate
expiry bounds the damage from a leaked key precisely *because* signatures are not timestamped, and
an attacker cannot extend that bound ([`notation-signing.md` §1](notation-signing.md)). A
timestamped signature outlives its certificate indefinitely. Make this an asserted configuration
with a comment explaining why, or someone will "fix" it.

**Identity:** a per-pipeline TPP service account, not a shared one — per-pipeline identities scale
and audit better, and the audit trail is the whole value here. Prefer an OAuth
client-credentials grant issuing a short-lived access token per run over a long-lived token in
GitHub secrets.

---

## 4. Phase 3 — CI

### What replaces what

| Today | Target |
|---|---|
| `NOTATION_SIGNING_KEY` — private key PEM in a GitHub secret, written to a runner tmpdir | *(gone)* — no key material on the runner |
| `NOTATION_SIGNING_CERT` — full chain PEM in a GitHub secret | *(gone)* — chain comes from the environment |
| `notation key add` via hand-written `signingkeys.json` + macOS config-dir workaround | `notation key add --plugin venafi-csp --id <label>` |
| ~60 lines of PEM validation and keystore merging in `sign-image.sh` | plugin config file + `notation sign` |

The runner ends up holding **one short-lived TPP token**, not a signing key.

### Sketch of the new `sign-image.sh` core

```bash
# --- plugin (pin the hash; mirror internally rather than pulling from GitHub in CI)
notation plugin install \
  --url    "$VENAFI_PLUGIN_URL" \
  --sha256sum "$VENAFI_PLUGIN_SHA256"

# --- config.ini holds the ACCESS TOKEN: same tmpdir + umask 077 + trap cleanup
#     discipline the current script already uses for the key.
cat > "$WORK/config.ini" <<EOF
tpp_url=${TPP_URL}
access_token=${TPP_ACCESS_TOKEN}
tpp_project=${TPP_PROJECT}
EOF
chmod 600 "$WORK/config.ini"

# --- register the remote key. Key Id SHOULD be the certificate label matching the
#     CodeSign Protect environment (vendor's stated best practice).
notation key add --default "$CERT_LABEL" \
  --plugin venafi-csp --id "$CERT_LABEL" \
  --plugin-config "config=$WORK/config.ini"

# --- sign the DIGEST of the already-pushed image (unchanged)
notation sign --signature-format cose --key "$CERT_LABEL" "$IMAGE"
```

### Checks that must survive the rewrite

The current script's guard rails exist because each failure otherwise surfaces on a cluster
instead of in CI. They do not come for free on the plugin path:

- **Complete chain in the envelope.** The plugin advertises
  `SIGNATURE_GENERATOR.ENVELOPE`, so *it* builds the envelope and embeds the chain — sourced from
  whatever the CodeSign Protect environment holds. If that object has only the leaf, signing
  succeeds and admission fails. `sign-image.sh`'s "refuse a bare leaf" check has no direct
  equivalent; replace it with a post-sign `notation verify` against the committed `trust/ca.crt`.
- **Leaf expiry / 30-day warning.** Today read from the PEM with `openssl -checkend`. Now it must
  come from the environment's certificate — fetch it, or query TPP.
- **Digest not tag.** Unchanged, and still the rule.
- **Fail closed.** Unchanged: an unsigned image is silently rejected at admission, which is a much
  worse place to discover the problem.

### Verification in CI

Add a `notation verify` step after signing, against the **committed** `trust/ca.crt` — not a copy
fetched from TPP, which cannot disagree with itself. This is the closest CI-side proxy for what
Wiz will conclude. It proves only what Notation concludes, not what Wiz does, but it catches the
chain and expiry failures before they reach a cluster.

Note the plugin also declares `SIGNATURE_VERIFIER.TRUSTED_IDENTITY` and emits a
`com.venafi.notation.plugin.x5u` attribute for identity validation on TPF 23.1+. **This does not
help at the Wiz gate** — Wiz will not run the plugin. It is useful for local and CI verification
only.

---

## 5. Phase 4 — what moves in this repo

| File | Change |
|---|---|
| `trust/ca.crt` | replace test PEM with the real root → `compute_matrix.py --bootstrap` = `true` |
| `terraform/bootstrap/` | **none** — `notary_ca_certificate` already reads from that file |
| cluster terraform | **none** — validator id stable, zero cluster re-applies |
| `scripts/render_bootstrap.py` | **none** |
| `scripts/sign-image.sh` | plugin path per §4; file-key path becomes local-test-only |
| `.github/workflows/unikube.yaml` | `NOTATION_SIGNING_CERT`/`_KEY` → `TPP_URL`, `TPP_ACCESS_TOKEN`, `TPP_PROJECT`, `CERT_LABEL` |
| `self-built-image/.github/workflows/deploy.yaml` | stubbed `NOTATION_KEY`/`NOTATION_CERT` drop out entirely |
| `scripts/gen_signing_certs.sh` | keep as local test material, relabel |
| `trust/README.md`, `notation-signing.md` | update §4 (PKI) and §7 (key custody) |
| CODEOWNERS | **none** — `/trust/` already carries the strictest rule |

**New supply-chain surface:** the plugin binary. `notation plugin install --sha256sum` pins it,
but pulling a release from GitHub during every build is a dependency worth removing — mirror the
binary internally and pin the hash, consistent with the rest of the air-gapped posture.

---

## 6. Operations

| Event | Cadence | Work | Fleet impact |
|---|---|---|---|
| **Leaf rotation** | ~365d | re-issue into the same CSM environment; `CERT_LABEL` unchanged if reused | none |
| **Intermediate** | by ~year 4 of 5 | new intermediate; old-chain images expire at the old intermediate's `notAfter` | none at the gate |
| **Root** | by ~year 5 of 10, or compromise | replace `trust/ca.crt`, bootstrap apply | **hard cutover, both tenants, everything re-signed** |
| **Key compromise** | — | revoke via CRL/OCSP *if* CDP/AIA present and Wiz can reach it; otherwise wait out expiry | up to 365d without revocation |
| **TPP unavailable** | — | builds cannot sign; nothing unsigned is admitted | **new hard dependency of the build path** |

That last row is the real operational change: signing becomes a network call to TPP. On-prem TPP
makes this far more palatable than a SaaS dependency would — and **verification is unaffected**,
since Wiz verifies offline from the embedded certificate. The air-gap reasoning that chose Notary
over cosign still holds.

Leaf rotation gets materially better: today it is "a human remembers, generates a key on a laptop,
and pastes a PEM into GitHub secrets". Under this design it is a certificate renewal inside TPP,
with the key never moving and no secret to update.

---

## 7. Separation of duties

The point of the design, and the part to get right in the project setup:

| Who | Can | Cannot |
|---|---|---|
| PKI / security | issue certs, administer keys, approve key use, change `/trust/` | invoke signing from CI |
| Platform (unikube) | run the pipeline, which invokes the pre-approved key | extract the key, issue certs, widen the trust anchor |
| Tenant repos | trigger builds | anything signing-related — they hold no signing material at all |

Compare to today, where whoever holds the GitHub secret *is* the signing authority.

---

## 8. Spike checklist — verify before committing

Each of these can invalidate a decision above.

1. Does the TPP-backed CA issue on the **Notary code-signing leaf profile**? (§2)
2. Does the CodeSign Protect environment return the **full chain**, or only the leaf? (§4)
3. Can the **timestamp service be disabled** per project and asserted in config? (§3)
4. Can the Key Use Approver **pre-approve** for a CI service identity, non-interactively? (§3)
5. **Token lifetime** — client-credentials grant per run, or a long-lived token in secrets?
6. Runner **egress to TPP** through the proxy allowlist?
7. Does the TPP issuing template enforce the **issuer clamp**, or must CI? (§2)
8. Can the dedicated root carry **CDP/AIA** with hosted CRL/OCSP?
9. Plugin version compatibility: README tests against notation **v1.3.2**; confirm against the
   version CI pins.
10. Still open from before, and unchanged by any of this: does
    `notary_v2.certificate` accept a **concatenated PEM bundle**? It decides whether a root
    cutover can ever have an overlap window
    ([`notation-signing.md` §8](notation-signing.md)).

**Do the spike before signing anything in production.** The root cutover is a hard cutover with no
overlap window, and it is free only while `trust/ca.crt` is still test material.

---

## Sources

- [`Venafi/notation-venafi-csp`](https://github.com/Venafi/notation-venafi-csp) — plugin install, `notation key add --plugin`, `config.ini` (`tpp_url`/`access_token`/`tpp_project`), key specs, plugin capabilities, cert-label naming guidance, tested notation version
- [Understanding CodeSign Protect Projects and Environments](https://docs.venafi.com/Docs/25.1/TopNav/Content/CodeSigning/c-codesigning-projects-environments.php) — projects, environments, key generation vs adoption, role assignment
- [Approving or rejecting use of code signing keys](https://docs.venafi.com/Docs/25.1/TopNav/Content/CodeSigning/r-codesigning-approveKeyUse.php) — Key Use Approver role, pre-approval
- [CodeSign Protect Guide 25.1 (PDF)](https://docs.venafi.com/Docs/25.1PDF/Code_Signing_Guide.pdf) — separation of duties, timestamp service, client setup
- [Install Trust Protection Platform with CodeSign Protect](https://docs.venafi.com/Docs/current/TopNav/Content/CodeSigning/t-codesigning-install.php) — module prerequisites
- [Notary Project signature specification](https://github.com/notaryproject/specifications/blob/main/specs/signature-specification.md) — certificate profiles, chain requirements
- [Notary Project plugin extensibility spec](https://github.com/notaryproject/notaryproject/blob/main/specs/plugin-extensibility.md) — `SIGNATURE_GENERATOR.ENVELOPE` semantics
