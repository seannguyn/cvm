# Venafi + Notation — master decision document

**Status: Option A agreed in principle (Bob, 2026-08-11). Blocked on PKI-team engagement.
Analysis only; nothing in the repo has been changed.**

Supersedes `venafi-pivot.md`, `venafi-tpp-signing-workflow.md`, `venafi-notation-tpp-tutorial.md`
(in [`history/`](history/) — do not cite). Still current, not repeated here:
[`notation-signing.md`](notation-signing.md), [`image-signing-101.md`](image-signing-101.md).

**Stack:** self-hosted **Venafi TPP** for issuance (Control Plane SaaS is discovery-only), plus
[`notation-venafi-csp`](https://github.com/Venafi/notation-venafi-csp).

### How to use this file

Questions are numbered `Q1…Qn` in [§8](#8-open-questions). Reply inline anywhere with:

```
> **A (Bob, YYYY-MM-DD):** …
```

Answered items get folded into the body. **[ASSUMED]** marks a load-bearing guess.
**[VERIFIED]** marks something confirmed against vendor docs or this repo, with the source linked.

### Round 2 changelog

- **Three things I got wrong are corrected in [§2](#2-corrections-to-round-1).** One of them
  (Kyverno) was a direct answer to your challenge — you were right to push.
- Q1, Q2, Q5, Q6, Q7 now have **documented answers**; the CodeSign Protect setup process is in
  [§5](#5-how-codesign-protect-is-actually-set-up).
- New [§3 glossary](#3-glossary) for CDP/AIA/CRL/OCSP and fail-open.
- Your workflow summary is confirmed with three corrections in [§7](#7-your-summary-checked).

### Round 3 changelog

- Your high-level plan is reviewed in [§10](#10-high-level-plan--reviewed), with the corrected
  end-to-end sequence in [§10.6](#106-the-corrected-sequence) — that table is the thing to take
  to the PKI team.
- **TPP → TPF rebrand confirmed** ([§10.1](#101-naming--youre-correct-verified)); your reading of
  the 26.1 docs was right.
- **ADCS is my assumption, not a verified fact about your org** — now marked as such
  ([§10.2](#102-which-ca--correct-to-ask-and-yes-adcs-is-my-assumption-assumed)).
- Two corrections: the CA template attaches to the **Environment** (and **Environment Templates**
  were missing from the chain), and what goes into Wiz is the **root only, via terraform**.

---

## 1. The constraint that decides everything

> **`wiz-v2_image_integrity_validator` gives us one control: which CA certificate(s) to trust.**
> No signer-identity pinning, no `trustedIdentities` equivalent.

Wiz asks one question at admission: *does this signature's chain terminate in a certificate we
gave it?* It cannot ask *"and was it our pipeline that signed?"*

**Therefore: whatever CA goes into `trust/ca.crt` is an unrestricted fleet-wide admission
authority.**

> **A (Bob, 2026-08-11):** *"If we use a dedicated root and guard the access_token, it should be
> safe. Hence prefer Option A? Otherwise other teams can sign with any certificate issued under
> the org root — assuming they have TPP access."*

**Correct, and worth separating into the two things it protects.** Under Option A there are two
independent locks, not one:

| Lock | What it stops | If it fails |
|---|---|---|
| **The dedicated root** | any other team's certificate being admitted at all | someone else can admit images fleet-wide — **unrecoverable without a root swap** |
| **The access token** | someone else using *our* environment to sign | attacker signs as us — but every signature is **attributed and audited** in TPP, and the token is revocable in minutes |

The token is the weaker lock and the recoverable one. The root is the strong lock. Under Option B
you only have the weak lock, and it does not even apply to the attacker — they use their own
certificate and never touch our token. That is the whole argument.

Your break-glass note in the comparison table is right and now folded in below.

---

## 2. Corrections to round 1

**① Kyverno does *not* support `trustedIdentities` for Notary. I was wrong.** [VERIFIED]

You asked for the exact document. There isn't one, because the capability doesn't exist. In
[Kyverno's Notary docs](https://kyverno.io/docs/policy-types/cluster-policy/verify-images/notary/),
a Notary attestor entry accepts **`certificates.cert`** (and `certChain`) and nothing else — no
subject or identity field:

```yaml
verifyImages:
  - type: Notary
    attestors:
      - entries:
          - certificates:
              cert: |-
                -----BEGIN CERTIFICATE-----
```

The `subject` / `issuer` pinning you may have seen is **Sigstore keyless only**, where the
identity comes from an OIDC token — a different mechanism entirely. And yes, `attestors` is the
right section you found; it just has no identity field for the Notary type.

**Consequence: "move to Kyverno later" is not a fix for this.** Kyverno has the same one-control
limitation Wiz does. That *strengthens* Option A — the dedicated root isn't a workaround for a
Wiz gap we'll grow out of, it's the only mechanism either engine offers. I've removed the
"revisit if enforcement moves to Kyverno" line.

**② Root rotation may not be a hard cutover after all.** [VERIFIED — your finding]

You pointed out `notary_v2` is a **list**, which the repo confirms —
[`bootstrap/main.tf`](../container-vulnerability-exemption.tf/terraform/bootstrap/main.tf) already
writes `notary_v2 = [{ certificate = ... }]` as a single-element list. So:

```hcl
notary_v2 = [
  { certificate = var.old_root },   # trusted during migration
  { certificate = var.new_root },
]
```

If Wiz evaluates every entry, root rotation becomes **add-new → re-sign → remove-old** with an
overlap window, instead of a hard cutover. That materially weakens the "migrate now while it's
free" urgency I pushed in round 1. Committed to memory. Two things still to confirm → **Q8**.

**③ Wiz enforcement is per-cluster, and dev is not blocking.** [VERIFIED]

Your Q4 answer assumed Wiz simply rejects unsigned pods. It does — **where enforcement is
`BLOCK`**. Per [`variables.tf`](../container-vulnerability-exemption.tf/terraform/variables.tf) the
default is `AUDIT`, and `test_render.py` asserts `dev/anp02` → `AUDIT`, `prod/apr01` → `BLOCK`.
So an unsigned image in dev is *reported*, not refused. Worth knowing before you test and
conclude signing works.

---

## 3. Glossary

You asked what CDP/AIA and CRL/OCSP mean. Plainly:

**The problem they solve.** A certificate says "valid until 2027". Suppose the key is stolen in
2026. How does a verifier find out? The certificate itself can't say — it was signed before the
theft. You need a way to ask the CA *"is this still good?"*

| Term | Expansion | What it is |
|---|---|---|
| **CRL** | Certificate Revocation List | A file the CA publishes listing revoked certificates. Verifier downloads it and checks. |
| **OCSP** | Online Certificate Status Protocol | A live query — verifier asks the CA about *one* certificate and gets good/revoked/unknown. Faster than a CRL. |
| **CDP** | CRL Distribution Point | A **field inside the certificate** holding the URL of the CRL. Without it, a verifier has no idea where to look. |
| **AIA** | Authority Information Access | Same idea, holding the **OCSP responder URL** (and often the issuer's certificate). |

So CDP and AIA are the *signposts*; CRL and OCSP are the *services* they point at.

**Why it matters here.** Our current certificates carry **neither** field. Notation therefore
performs no revocation check — the spec says if a certificate has no OCSP or CRL information,
*"no revocation check is performed and the certificate is considered valid"*. That's why
[`notation-signing.md` §2](notation-signing.md) calls validation 5 a no-op.

**Practical consequence:** if the signing key leaks, we cannot revoke. We wait for the
certificate to expire — up to 365 days. With CDP/AIA present and reachable, revocation takes
minutes. That is the entire content of Q3, and it's why I keep flagging it.

**Fail-open vs fail-closed** (your other question). Not about signatures — about the *admission
controller itself*. If the Wiz admission webhook can't reach the Wiz backend, does it (a) let
everything through, or (b) block everything? Fail-open is a security hole; fail-closed can take
out a cluster during a Wiz outage. Only matters where enforcement is `BLOCK` — i.e. **prod**.

---

## 4. The decision

### Option A — dedicated root *(agreed)*

> **A (Bob, 2026-08-11):** *"Understood. So have to get PKI team endorsement and onboard. Since it
> is large org, cannot risk our platform doing things in silo."*

Agreed, and §5 below is the concrete ask to bring them.

### Option B — org root *(rejected)*

Rejected on the §1 argument. Recorded so the reasoning survives: its one real advantage was
CRL/OCSP revocation, which is transferable to a dedicated root (**Q3**), and the cost is that
widening fleet-wide admission authority becomes a Venafi admin action in another system rather
than a security-approved PR here.

### Comparison

| | **A — dedicated root** | **B — org root** |
|---|---|---|
| Who can admit fleet-wide | our pipeline — plus anyone holding the CI token (break-glass path; audited + revocable) | anyone with an org code-signing cert |
| Boundary enforced by | HSM custody + `/trust/` CODEOWNERS | Venafi policy, in another system |
| Widening it requires | security-approved PR here | a Venafi admin action, invisible here |
| Root rotation schedule | ours | the org's |
| Blast radius of an org PKI event | none | every image, both tenants |
| Revocation | expiry only — unless CDP/AIA (**Q3**) | CRL/OCSP, *if* reachable (**Q4**) |
| PKI-team sign-off | required | not required |

**Decision: Option A.** No revisit trigger remains — see correction ① (Kyverno has the same
limitation, so there is nothing to migrate *to*). Only a `trustedIdentities` equivalent appearing
in Wiz itself would reopen this.

---

## 5. How CodeSign Protect is actually set up

You asked for the real process from the vendor docs rather than my invention. This section is
[VERIFIED] against
[Projects and Environments](https://docs.venafi.com/Docs/25.1/TopNav/Content/CodeSigning/c-codesigning-projects-environments.php)
and [CA templates](https://docs.venafi.com/Docs/currentSDK/TopNav/Content/CodeSigning/t-codesigning-create-templates.php).

### 5.1 Does Venafi provide the CA? No — it connects to one. **Q1 RESOLVED**

**Each environment in a code signing project must have a CA template assigned to it.** Supported
CA template types:

> Adaptable CA · DigiCert · Entrust Certificate Service · **Microsoft CA** · Microsoft CA Pool ·
> Out-of-band · Sectigo · **Self-signed**

This confirms TPP is a **CA-agnostic control plane** — it orchestrates a CA, it isn't one (with
"Self-signed" as the exception, and "Adaptable CA" as the scripting escape hatch). So the
dedicated hierarchy is created **on whichever CA backs TPP** — most likely **Microsoft CA
(ADCS)** — and then a CA template pointing at it is assigned to our environment.

**Your ask to the PKI team becomes concrete:**

1. A dedicated code-signing hierarchy on the backing CA (not the org root).
2. An ADCS (or equivalent) **certificate template** for code signing → §5.3.
3. A CodeSign Protect **CA template** pointing at (2).
4. A **Project + Environment** using that CA template → §5.2.

### 5.2 Is the intermediate needed? Effectively yes — you get it for free. **RESOLVED**

You asked whether `Image Signing CA` is necessary or whether the root alone suffices.

**You don't really choose.** For a Microsoft CA connector, TPP talks to an *online issuing CA* —
and in any standard ADCS deployment that issuing CA **is** the intermediate, sitting under an
offline root. So the three-tier shape isn't an extra request; it's how the platform is built.
Asking for "root only" would mean an online root signing leaves directly, which no PKI team will
agree to.

The blast-radius argument in [`notation-signing.md` §4](notation-signing.md) independently
supports it: compromise of an issuing CA means issue a new intermediate; compromise of a root
means replace `trust/ca.crt` and re-sign everything.

### 5.3 The leaf profile. **Q2 RESOLVED**

You asked how this happens today and whether it's documented. It is — and the answer is that
**Venafi does not define the profile; the backing CA does.** For the Microsoft CA connector, the
CA template has a `Template` field, described as:

> *"The Microsoft CA template that you want to associate with the current CA Template object.
> Trust Protection Platform references this template when it submits the CSR."*

So the leaf profile lives in the **ADCS certificate template**. This is good news: ADCS ships a
built-in **Code Signing** template whose EKU is `1.3.6.1.5.5.7.3.3 (Code Signing)` with Key Usage
`Digital Signature` — which is exactly the Notary leaf profile. **This is a standard, well-trodden
request, not an exotic one.**

Ask the PKI team for a duplicated Code Signing template with:

| Setting | Value | Why |
|---|---|---|
| EKU | `Code Signing` only | no `serverAuth`/`clientAuth`/`timeStamping`/`anyEKU` |
| Key Usage | `Digital Signature` | no `keyCertSign`/`cRLSign` |
| Basic Constraints | `CA:FALSE` | it's a leaf |
| Validity | **365 days** | with no timestamping, leaf lifetime = image admissibility |
| Subject | supplied in request, full DN incl. `OU=Platform-Unikube` | ADCS template must be *"configured to have its Subject Name supplied in the request"* [VERIFIED] |
| Key | RSA-3072 or EC P-384 | intersection of plugin support and CSM support — see §5.5 |

Also set **Manual Approvals = off** on the Venafi CA template, or *"the administrator must log in
to the Microsoft CA service and manually approve the renewing certificate"* — which would stall
automated renewal.

### 5.4 The issuer clamp. **Q5 — partially resolved, keep the CI check**

You asked what the point of a product is if it lacks basic checks. Fair. The honest answer:
**the clamp isn't Venafi's job here** — validity comes from the ADCS template, and ADCS
*truncates* an issued certificate to the CA's remaining lifetime rather than refusing. **[ASSUMED
— standard ADCS behaviour, confirm with PKI]**

Truncation is precisely the failure mode we care about: the certificate quietly comes back with
less life than requested, and images stop being admissible earlier than anyone expects. So the
check stays in CI — not because Venafi is deficient, but because a *silent* clamp is worse than
none. It's ~10 lines: compare the issued leaf's `notAfter` against what we asked for and fail
loudly on a mismatch.

### 5.5 Environment configuration

Private key sources available [VERIFIED] — five options; **two** are right for us:

- **"Create a new key and have TPP handle the certificate life cycle"** — TPP generates the key in
  the selected key storage location, issues the certificate through the environment's CA, and puts
  it in **Enrollment mode** (i.e. TPP renews it). *This is the default choice.*
- **"Import existing key in HSM and have TPP handle the certificate life cycle"** — if the PKI
  team wants the key pre-created in a specific HSM partition. Also Enrollment mode.

Avoid the PKCS#12 import and plain HSM-import options: both land the certificate in **Monitoring
mode**, meaning no automated renewal, and the PKCS#12 path is serviced by the *software* driver
rather than the HSM.

| Setting | Value | Source |
|---|---|---|
| Environment type | **Single** (not per-user) | per-user is for macro/git-commit signing |
| Key spec | RSA-3072 or EC P-384 | CSM supports RSA 1024–8192 and P256/384/521 + Ed25519; the **plugin** supports RSA-2048/3072/4096 and EC-256/384/521 — **Ed25519 and RSA-8192 are out** |
| Key source | create-new, TPP-managed lifecycle | §5.5 above |
| **IP restrictions** | pin to CI runner egress | environment-level control, [VERIFIED] — a genuinely useful extra lock on the token |
| **Permitted signing applications** | must include the vSign/notation client | project-level allowlist; blank = any |
| **"Key Users may not have other roles"** | **on** | Venafi: *"should typically be checked"*; prevents a project admin granting themselves signing rights |
| Role members must be groups | on | survives staff turnover |

Note roles are evaluated **at key-use time**, not project-creation time.

### 5.6 Approval flow. **Q7 RESOLVED — and my round-1 framing was imprecise**

> **A (Bob, 2026-08-11):** *"What does 'pre-approval, not interactive approval' mean? All keys
> approved automatically on generation? Is it FYI or something to implement?"*

Neither, and I under-explained it. Here is the actual model [VERIFIED]:

**Approval is driven by a "Flow"**, configured by the Code Signing Administrator. Three cases:

1. **Flow with no approval action** → signing just works, no human involved. **This is what CI
   needs, and it's the simplest answer.**
2. **Flow with an approval action** → after a key user attempts to sign, an approver gets an
   email and reviews the request. Fine for a human signing a release; **fatal for CI**, which
   would hang on every build.
3. **Flow with both a Pre-Approval action *and* an approval action** → a Key Use Approver can
   grant a pre-approval in advance, via Aperture or `POST Codesign/AddPreApproval`, and the normal
   approval steps are bypassed.

**So: it's something to implement, and the ask is case 1 unless your security org mandates an
approval Flow — in which case it's case 3.**

Two traps in case 3 worth knowing before you choose it:

- Pre-approvals have a **Valid Until** and are for a named Key User. They expire. Something must
  re-issue them, or builds start failing on a date nobody has in a calendar.
- **"Once a pre-approval is granted, it cannot be edited or canceled. It closes either when it's
  used or its date expires."** [VERIFIED] So an over-broad pre-approval — say unlimited use for a
  year — **cannot be revoked**. Regular *approvals* can be cancelled; pre-approvals cannot. Prefer
  case 1 with tight token control and IP restrictions over a long unlimited pre-approval.

### 5.7 Timestamping — **off, but conditionally**

> **A (Bob, 2026-08-11):** *"No need timestamping if it is worthless. Image expiring on leaf
> certificate expiry is fine."*

Off for now, and the *why* matters because someone will challenge it later: timestamping isn't
worthless in general — it's actively harmful **given our current constraints**. Certificate expiry
is our only revocation mechanism, and it works because an attacker can't extend it. A timestamped
signature survives certificate expiry indefinitely, so enabling it today would mean a leaked key is
usable **forever** rather than for ≤365 days. Put that reason in the config comment.

**But "image expiring on leaf certificate expiry is fine" is worth re-examining** — §6.5 works
through what it actually costs, and it's more than it sounds: images signed late in the leaf's life
get only the remainder, and every image under a given leaf becomes unadmissible simultaneously.

So this decision is **conditional on Q3**. If the signing certificate can carry CDP/AIA with
working CRL/OCSP, revocation no longer depends on expiry, timestamping becomes safe, and the entire
re-signing burden disappears. Revisit if Q3 lands.

---

## 6. Target design

### 6.1 PKI

| Tier | Validity | Custody | Destination |
|---|---|---|---|
| Container Signing Root CA | 10y | offline, HSM | `trust/ca.crt` → Wiz |
| Image Signing CA (= ADCS issuing CA) | 5y | HSM, online | travels in the chain |
| `unikube-image-signer` leaf | 365d | CodeSign Protect key store | signs; never leaves |

### 6.2 CI

```bash
notation plugin install --url "$VENAFI_PLUGIN_URL" --sha256sum "$VENAFI_PLUGIN_SHA256"

cat > "$WORK/config.ini" <<EOF
tpp_url      = ${TPP_URL}/vedsdk
access_token = ${TPP_ACCESS_TOKEN}
tpp_project  = ${TPP_PROJECT}        # "Project\Environment", e.g. container-image-signing\unikube-image-signer
EOF
chmod 600 "$WORK/config.ini"

notation key add --default "$CERT_LABEL" --plugin venafi-csp --id "$CERT_LABEL" \
  --plugin-config "config=$WORK/config.ini"

notation sign --signature-format cose --key "$CERT_LABEL" "$IMAGE"   # digest, never tag
```

> **A (Bob, 2026-08-11):** *"What is `$CERT_LABEL`? Can you be transparent? This is a guide doc,
> right?"*

Fair — I was copying the vendor's placeholder without saying so. Being explicit:

| Variable | Where it comes from | Who gives it to you |
|---|---|---|
| `TPP_URL` | your TPP server, e.g. `https://tpp.example.com` (the plugin wants the `/vedsdk` path) | TPP admin |
| `TPP_PROJECT` | literally `Project\Environment` — the two names from §5.1 step 4 | you propose, PKI creates |
| `CERT_LABEL` | **the certificate label on the CodeSign Protect environment.** Not something we invent — it's assigned when the environment is created, and read back with `pkcs11config getcertificate`. Venafi's guidance is to name the notation key ID identically. | PKI team, at setup |
| `TPP_ACCESS_TOKEN` | OAuth token for the CI service identity | you mint per run |

In the vendor README these all appear as `vsign-rsa2048-cert`, which is just their example
label. Concretely, ours would likely be `unikube-image-signer` for both the environment and the
label. **Nothing here is a value we choose at sign time — three of the four are outputs of §5
setup**, which is why §5 has to happen first.

**Runnable walkthrough:** [`../venafi-local-demo/`](../venafi-local-demo/) is a copy-paste
tutorial that does this on a laptop — local registry, build, push, sign, inspect, verify — with
**Option 1 (self-signed, works today)** and **Option 2 (Venafi plugin)** side by side, so the diff
between them is concrete. Its §2.6 is the **Q6 chain test**.

**Guard rails to keep:**

- **Complete chain** — the plugin builds the envelope (`SIGNATURE_GENERATOR.ENVELOPE`) and sources
  the chain from the environment. Verify with `notation inspect`, which prints the `certificates`
  list, and with a post-sign `notation verify` against the **committed** `trust/ca.crt` → **Q6**.
- **Leaf expiry warning** — now read from the environment's certificate, not a local PEM.
- **Digest not tag**, **fail closed**. Unchanged.
- **Mirror the plugin binary internally** and pin `--sha256sum`.

### 6.3 `trustedIdentities`

> **A (Bob, 2026-08-11):** *"Just use trustedIdentities for now for a comprehensive solution. If
> Wiz adopts it, the implementation is already ready."*

Agreed, with one clarification about what "ready" means. `trustedIdentities` is **verifier-side
configuration** — there is nothing to pre-install in Wiz. What we can do is:

1. Use it in the **CI-side `notation verify`** step, pinning `OU=Platform-Unikube`. Real value
   today: it catches a mis-issued certificate in CI.
2. Keep the **full-DN discipline** on every leaf (§5.3). That's the actual readiness — a leaf with
   only `CN=` and `O=` *cannot* be pinned by a valid policy later.

Given correction ①, note this no longer buys Kyverno readiness, because Kyverno's Notary attestor
has no identity field either. It buys CI-side checking and optionality if **Wiz** adds the field.

### 6.4 What moves in this repo

> **A (Bob, 2026-08-11):** *"Ok noted."* — unchanged from round 1, not repeated. Summary: one file
> (`trust/ca.crt`) plus one bootstrap apply; `sign-image.sh` gains the plugin path; workflow
> secrets change; zero cluster re-applies.

### 6.5 The expiry cliff — an operational cost not previously stated

Raised by Bob, 2026-08-11, and the analysis above understated it. Because signatures are not
timestamped, **image admissibility is pinned to the leaf's `notAfter`, not to signing time**:

- Sign on day 0 of a 365-day leaf → 365 days of admissibility.
- Sign on day 300 → **65 days**.
- Every image signed under that leaf becomes unadmissible **at the same instant**, regardless of
  when it was signed. It is a cliff, not a per-image sliding window.

Rotating the leaf on schedule does *not* rescue images already signed under the old one — new
builds get the new certificate; existing signatures still die on the old certificate's `notAfter`.
Earlier rounds described leaf rotation as having "no fleet impact"; that is true **at the gate**
(no cluster re-applies, no trust-anchor change) but **not** for the deployed estate.

Three mitigations, all needed:

1. **Re-sign, don't replace.** An image can carry multiple Notation signatures as separate referrer
   artifacts, and verification succeeds if any one validates. On renewal, re-sign existing digests
   under the new leaf and leave the old signature in place — no rebuild, no flag day.
2. **Renew far more often than the certificate lives.** Because renewals overlap (each certificate
   runs to its own `notAfter`; new signatures use the newest), the floor is:

   ```
   minimum admissibility = certificate validity − renewal interval
   ```

   A 365-day leaf renewed annually gives a late-signed image ~0 days. Renewed **quarterly** it
   guarantees ~275 days. Each renewal is a TPP-side operation on the same environment — same label,
   same subject, **no CI change, no secret to update**. This is the cheapest lever available and it
   is currently unspecified in the design.
3. **Lean on the rebuild cadence.** Images rebuilt monthly for CVE patching are re-signed as a side
   effect. In effect **the leaf lifetime sets a maximum shelf life for a deployed image** — which
   is arguably a feature, since it turns "not rebuilt in a year" into a deployment failure rather
   than a silent risk.

**Considered and rejected: a fresh leaf per signature.** It fixes the leaf tier — every image would
get a full 365 days from its own signing time — but (a) it only relocates the cliff, since a leaf
can't outlive its issuer and every image under a given intermediate still dies together on the
intermediate's `notAfter`; (b) a CodeSign Protect Environment holds one key and one certificate, so
per-build issuance means a CA enrollment per build and thousands of untracked code-signing
certificates a year; and (c) if the key is reused it buys nothing, and if it isn't, it's HSM keygen
per pipeline run against a threat (key theft) that non-exportable keys already close. Adjacent to
the "why not mint an intermediate per build" reasoning already in
[`notation-signing.md` §4](notation-signing.md).

New work this implies: an inventory of what's deployed and when it was signed (`notation inspect`
gives `signingTime`), alerting on the **old** certificate's `notAfter` rather than on renewal, and
an owner for re-signing — which is not a build-time action and won't be triggered by any code
change.

**This also changes the weight of Q3.** The cliff is the strongest argument for timestamping, which
we reject only because expiry is currently our sole revocation mechanism. That trade is
conditional: **if the signing certificate can carry CDP/AIA with working CRL/OCSP, timestamping
becomes viable** — real revocation replaces expiry as the kill switch, and we get durable
signatures *and* revocability. Q3 was framed as "closes the revocation gap"; it is better framed as
"unlocks a materially simpler operational model". It should be asked early, not treated as a
nice-to-have.

---

## 7. Your summary, checked

> **A (Bob, 2026-08-11):** 1. Work with PKI team to create dedicated CA. 2. PKI team sets up
> CodeSign Protect Project + Certificate Environment. 3. Our team checks compliance and consumes
> CodeSign Protect [code block]. 4. Wiz does its thing.

**Correct in shape.** Three corrections:

**Step 1 is two things, possibly two teams.** The dedicated hierarchy on the backing CA (ADCS),
*and* the ADCS code-signing certificate template (§5.3). The template is the part most likely to
be forgotten, and it's the one that fails verification if wrong.

**Step 2 needs the Flow decision made explicitly** (§5.6). If the PKI team sets up the project
with a default approval Flow, CI hangs on the first build waiting for a human. Specify "no
approval action for this environment" up front.

**Step 4 — "Wiz does its thing" depends on the cluster.** Prod is `BLOCK`, dev is `AUDIT`
(correction ③). Test in a `BLOCK` cluster or you'll get a green result that proves nothing.

One addition: between 3 and 4, keep a **`notation verify` in CI**. Wiz only tells you *"rejected"*
long after the fact, on a cluster; `notation verify` tells you *why*, in the build.

---

## 8. Open questions

| # | Question | Owner | Status |
|---|---|---|---|
| Q1 | Which CA backs TPP; can it host a dedicated hierarchy? | PKI | **RESOLVED** → §5.1. TPP is CA-agnostic (8 connector types). Confirm *which* one this org uses. |
| Q2 | Can it issue the Notary code-signing leaf profile? | PKI | **RESOLVED** → §5.3. Profile comes from the ADCS certificate template; the built-in Code Signing template already matches. |
| Q3 | Can the dedicated root carry **CDP/AIA** with CRL/OCSP? | PKI | **OPEN — highest value, and higher than first assessed.** Not just "closes the revocation gap": it is the precondition for timestamping, which would remove the expiry cliff entirely (§6.5). Ask early. |
| Q4 | Can Wiz's admission controller reach CRL/OCSP through the proxy allowlist? | Platform | **OPEN** — only matters if Q3 lands. Separate from "does Wiz block", see correction ③. |
| Q5 | Does anything enforce the issuer clamp? | PKI | **PARTIAL** → §5.4. Assume silent truncation; keep the CI check. Confirm ADCS behaviour. |
| Q6 | Full chain or bare leaf from the environment? | TPP admin | **OPEN** — not documented. Test with `notation inspect`. Still the likeliest cause of a green build and a rejected image. |
| Q7 | Pre-approval for a CI identity; timestamp service off? | TPP admin | **RESOLVED** → §5.6 (ask for a no-approval Flow), §5.7 (timestamping off). |
| Q8 | Does Wiz evaluate **every** `notary_v2` entry, or only the first? And does `trust/ca.crt` need to become multi-file? | Wiz / Platform | **OPEN** — promoted. Decides whether root rotation gets an overlap window (correction ②). |
| Q9 | Token lifetime — per-run OAuth grant, or long-lived secret? | Platform | **PARTIAL** — egress confirmed. Grant type still open; matters more now the token is the recoverable lock (§1). |
| Q10 | Prod/non-prod separate environments? | Security | **RESOLVED** — one shared CA, compliance-based. Consider separate *environments* under one hierarchy anyway, for per-env IP restrictions and audit separation. |
| Q11 | What **renewal interval** is set on the environment, and can it be set well below the certificate's validity? | TPP admin | **OPEN — new, and the cheapest lever available.** Worst-case admissibility is `validity − renewal interval` (§6.5). Annual renewal of an annual certificate leaves late-signed images with almost no life; quarterly renewal fixes it with no CI change and no secret rotation. |

**Now blocking:** Q3 (ask alongside the §5 request — it's cheap at build time, expensive later),
Q6 (test), Q8 (test). **Q11 is cheap and should go in the same conversation as Q3.**

---

## 9. Decision log

| Date | Decision | By |
|---|---|---|
| 2026-08-11 | **Option A — dedicated root.** Org root rejected: Wiz has no identity pinning, so the anchor is the authorization boundary. | Bob |
| 2026-08-11 | **No timestamping** — *conditional on Q3.* Certificate expiry is the intended revocation mechanism while no CRL/OCSP exists. Revisit if CDP/AIA lands: it would remove the expiry cliff (§6.5). | Bob |
| 2026-08-11 | Kyverno is **not** a future fix — same one-control limitation as Wiz. | analysis |
| — | Flow type for the CI environment (no-approval vs pre-approval) — **pending** | |

---

> **A (Bob, YYYY-MM-DD):** So as I understood it, there are:
- CA requirement. I don't know what CA yet. probably have to talk to PKI team, to see which CA they use. In your docs your are referencing: Microsoft CA (ADCS) correct?
- PKI team to help setup CodeSign Protect on Trust Protection Platform (TPP) but now called Trust Protection Foundation (TPF) in latest [docs](https://docs.venafi.com/Docs/26.1/TopNav/Content/CodeSigning/c-codesigning-projects-environments.php?tocpath=CodeSign%20Protect%7CUnderstanding%20CodeSign%20Protect%7C_____5)? This involves: 
  - creating Project, which will require a CA template that points to the actual CA?
  - Environments, Users & Approvers. 
- Then I just use Notation venafi plugin to sign images.
- On Wiz I configure CA so it can verify signed images

Correct?

---

## 10. High-level plan — reviewed

**Shape is right. Two corrections, one naming confirmation, and three things missing.**

### 10.1 Naming — you're correct [VERIFIED]

The rebrand is real and your link is the current doc. CyberArk acquired Venafi in Oct 2024, and
the 26.1 docs use the new names throughout:

| Old | Current (26.1) |
|---|---|
| Venafi **Trust Protection Platform (TPP)** | CyberArk **Trust Protection Foundation (TPF)** — the common platform layer |
| **CodeSign Protect** | CyberArk **Code Sign Manager - Self-Hosted** |
| **TLS Protect** | CyberArk **Certificate Manager - Self-Hosted** |

Two practical notes. The plugin README's *"TPF 23.1+"* is retconned naming — it means **TPP
23.1+**, since TPF branding only appears at 26.1; don't go looking for a "TPF 23.1" release.
And the 26.1 page carries a **Palo Alto Networks** copyright, so the vendor relationship may have
moved again — worth confirming who your account team actually is.

Content is otherwise **identical** between 25.1 and 26.1 for projects and environments, so §5
stands unchanged. This doc keeps saying "TPP/CodeSign Protect" because that's what your install
almost certainly still reports; use the new names when talking to CyberArk.

### 10.2 Which CA — correct to ask, and yes, ADCS is my assumption [ASSUMED]

You're right that I've been referencing Microsoft CA (ADCS). **That is an assumption, not
something I verified about your org** — it's the most common enterprise choice and one of eight
supported connectors (§5.1). Flag it as such when you ask.

If it turns out to be EJBCA, Entrust, DigiCert or Sectigo, **only §5.3 changes** — the leaf
profile would come from that CA's own template mechanism instead of an ADCS certificate template.
The shape of the ask, the hierarchy, and everything downstream are unaffected.

### 10.3 Correction — the CA template attaches to the Environment, not the Project

You wrote *"creating Project, which will require a CA template that points to the actual CA"*.
Close, but the ordering matters when you ask, because two of these are **admin prerequisites you
cannot do yourself**:

> *"Each environment in a code signing project must have a CA template assigned to it."*
> *"Project environments are based on Environment Templates, which are configured by the Code
> Signing Administrator. The environment template selection will restrict what options can be
> configured when setting up project environments."* [VERIFIED]

**There's a layer missing from your list: Environment Templates.** They gate everything — *"anyone
who can login to Aperture can create a new Project **if they have access to at least one
environment template**"*. No environment template, no project. And the CA template is assigned to
the **Environment**, not the Project.

Also note the Project itself needs approval: new project requests go to the **Code Signing
Administrator**, and the requester becomes the **Owner**.

### 10.4 Correction — what goes into Wiz is the root, via terraform

You wrote *"On Wiz I configure CA."* Right idea, two precisions:

- It's the **root certificate only** — not the leaf, not the full chain. The chain travels inside
  the signature; Wiz holds the anchor.
- It isn't configured in the Wiz console. It's `trust/ca.crt` → `render_bootstrap.py` →
  **bootstrap terraform apply**. One file, one apply, zero cluster re-applies.

### 10.5 Missing — three things that will bite

1. **The certificate template / leaf profile (§5.3).** The single most likely thing to be
   forgotten, and it fails *silently at admission* rather than at setup. A TLS-shaped template
   gives you `serverAuth` in the EKU, which fails Notary verification.
2. **The Flow decision (§5.6).** If the project is created with a default approval Flow, CI hangs
   on the first build waiting for a human to click approve. Ask for **no approval action** on this
   environment up front.
3. **Test the chain (Q6) before wiring the pipeline.** `notation inspect` on a test image shows
   the `certificates` list. If the environment returns a bare leaf, signing succeeds and admission
   fails — the worst failure shape available.

### 10.6 The corrected sequence

| # | Step | Who | Blocks |
|---|---|---|---|
| 1 | Identify the CA behind TPP/TPF | PKI | everything |
| 2 | Dedicated code-signing hierarchy (offline root + issuing CA) | PKI | 3 |
| 3 | **Certificate template** for the code-signing leaf profile (§5.3) | PKI | 4 |
| 4 | **CA template** in Venafi pointing at (3) | Code Signing Admin | 5 |
| 5 | **Environment Template** | Code Signing Admin | 6 |
| 6 | **Project** + **Environment** (single, create-new key, TPP-managed lifecycle) | you request → CSA approves | 7 |
| 7 | **Users & Approvers** + **Flow** (no approval action) + IP restrictions | Owner / CSA | 8 |
| 8 | Receive `TPP_PROJECT`, `CERT_LABEL`, CI service identity + token | PKI → you | 9 |
| 9 | Wire `sign-image.sh` to the plugin; add `notation verify` in CI | you | 10 |
| 10 | Root PEM → `trust/ca.crt` → bootstrap apply | you | — |
| 11 | Test in a **`BLOCK`** cluster, not dev (correction ③) | you | — |

Steps 1–7 are all PKI/admin. **Your part is 9–11**, and it's small — which is the point.

## Sources

**Repo:** [`notation-signing.md`](notation-signing.md) ·
[`trust/README.md`](../container-vulnerability-exemption/trust/README.md) ·
[`bootstrap/main.tf`](../container-vulnerability-exemption.tf/terraform/bootstrap/main.tf) ·
[`variables.tf`](../container-vulnerability-exemption.tf/terraform/variables.tf) ·
[`sign-image.sh`](../container-vulnerability-exemption/unikube/scripts/sign-image.sh)

**Venafi / CyberArk:**

- [Projects and Environments](https://docs.venafi.com/Docs/25.1/TopNav/Content/CodeSigning/c-codesigning-projects-environments.php) — environments, the five private-key sources, key types, rules & restrictions, role options
- [Create CA templates](https://docs.venafi.com/Docs/currentSDK/TopNav/Content/CodeSigning/t-codesigning-create-templates.php) — the eight supported CA connector types
- [Create a Microsoft CA template](https://docs.venafi.com/Docs/25.1/TopNav/Content/CodeSigning/t-codesigning-create-msca.php) — `Template` field, subject-in-request requirement, Manual Approvals
- [Approving or rejecting use of code signing keys](https://docs.venafi.com/Docs/25.1/TopNav/Content/CodeSigning/r-codesigning-approveKeyUse.php) — Flows, pre-approval, the no-cancel rule
- [`notation-venafi-csp`](https://github.com/Venafi/notation-venafi-csp) — plugin config, key specs, capabilities

**Specs / other engines:**

- [Kyverno Notary verification](https://kyverno.io/docs/policy-types/cluster-policy/verify-images/notary/) — attestor accepts certificates only (correction ①)
- [Notary signature specification](https://github.com/notaryproject/specifications/blob/main/specs/signature-specification.md) — certificate profiles, chain requirements
- [Trust store and trust policy specification](https://github.com/notaryproject/specifications/blob/main/specs/trust-store-trust-policy.md) — `trustedIdentities`, revocation behaviour
