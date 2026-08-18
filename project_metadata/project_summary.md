# Project Summary — Container Vulnerability Exemption

The single entry point. Read this, then the READMEs it points to, and you know the system end
to end.

- **[`container-vulnerability-exemption/unikube/README.md`](../container-vulnerability-exemption/unikube/README.md)** — the interface: exemption YAML schema and the command surface.
- **[`container-vulnerability-exemption/image-signing/README.md`](../container-vulnerability-exemption/image-signing/README.md)** — the signing PKI, `sign-image.sh`, and verifying against the committed trust root.
- **[`container-vulnerability-exemption.wiz/README.md`](../container-vulnerability-exemption.wiz/README.md)** — backend A: the Wiz objects, state model, local plan.
- **[`container-vulnerability-exemption.kyverno/README.md`](../container-vulnerability-exemption.kyverno/README.md)** — backend B: the Kyverno object model and why it is not a translation of A.
- **[`wiz_kyverno_solution_parrallel_PLAN.md`](wiz_kyverno_solution_parrallel_PLAN.md)** — how the two-backend structure was built, and the decisions behind it.
- **[`image-signing-101.md`](image-signing-101.md)** / **[`notation-signing.md`](notation-signing.md)** — the trust model, and the Notation operational reference.
- **[`terraform-rework_PLAN.md`](terraform-rework_PLAN.md)** — why there is one Wiz state per tenant, and what was removed to get there.

> Historical records — `new_direction*.md`, `terraform-rework_PLAN.md`,
> `ignore_rules-rework_PLAN.md` and everything in `history/` — predate the two-backend split and
> still say `container-vulnerability-exemption.tf`. They are kept as provenance; this file and
> the four READMEs above are current.

## What this system does

It lets teams manage container-vulnerability **exemptions** and **admission** for the unikube
EKS fleet (200+ clusters) through reviewed YAML instead of clicking in a console. Customers
declare which images may be exempted on their cluster; CI validates and renders that YAML into
backend objects.

## One interface, two backends

```
container-vulnerability-exemption/        <- tenants edit ONLY this
  unikube/exemptions/<env>/*.yaml
        |
        |  unikube/scripts/wiz_render.py          unikube/scripts/kyverno_render.py
        v                                          v
  .wiz/  one tfvars per Wiz tenant           .kyverno/  one manifest dir per cluster
         -> terraform apply -> Wiz API              -> kubectl apply / GitOps -> ~200 etcds
```

| | `.wiz` (mature) | `.kyverno` (challenger) |
| --- | --- | --- |
| control plane | one tenant API | ~200 cluster etcds |
| one apply covers | a whole Wiz tenant | one cluster |
| an exemption becomes | one more prefix in a shared ignore rule | its own `PolicyException` |
| env-wide exemption | **1 shared object** | 1 object **× N clusters** |
| CA rotation | **1 in-place update** | a diff in every cluster directory |
| per-entry expiry / operator | impossible | yes |
| scoping | image name only | also namespace / resource / CEL |
| vulnerability scanning | **yes** | **no** — admission only |
| partial-failure state | cannot exist | possible, and needs to be visible |

The bottom two rows are ADR-0002 rationales 1 and 2. **Nothing in the Kyverno work moves
them:** a `PolicyException` answers "may this image be admitted", never "do we accept this CVE",
and fan-out to ~200 etcds is what the table's middle rows are. The Kyverno backend exists to
make the comparison *fair and concrete*, not to pre-empt it.

What the Kyverno work did settle, and what the ADR should be corrected for:

1. **Kyverno has no Notary signer-identity pinning** (`TrustedIdentities: ["*"]`, hardcoded in
   Go, no CRD knob). ADR-0003's claim that it "supports it today" is wrong. On **both** backends
   the trust store is the only authorization boundary, which is what makes ADR-0003's standalone
   signing root necessary rather than tidy.
2. **`PolicyException` gets native `expiresAt` + `properties` in v1.19**, retiring ADR-0002
   rationale 3 ("expiry is a first-class field in Wiz, composed in Kyverno").
3. **`validationConfigurations.required` is unusable here**, on either version — not because
   1.18 ignores it, but because it is not a policy, so no exception can target it. An exempted
   vendor image would be denied with nothing to except it from. The catch-all policy is what
   exemptions are excepted *from*.

## Admission model — signature (compliant) + exemption (everything else)

Identical on both backends:

- **Compliant self-built images** are admitted by **signature**. The unikube workflow builds →
  compliance-checks → pushes → **Notation-signs the pushed digest**. Wiz's shared NOTARY
  validator / Kyverno's `soe-notary-signed` verifies against the CA in repo-root `trust/*.crt`.
  Signed ⇒ admitted **fleet-wide**; no YAML, no PR, `target_clusters` not consulted.
- **Everything else** (vendor/OSS, accepted-risk, non-compliant self-built) needs a manual,
  security-approved **exemption** in `unikube/exemptions/`.

**Push precedes sign** because a Notation signature is an OCI artifact stored in the registry as
a referrer to the image manifest — there is nothing to attach it to until the image is there. So
"pushed" never implies "admissible".

There is no vuln scan policy on either backend: it was informational and its result was ignored
on both branches.

## Exemption schema

```yaml
admission:
  enforcement: BLOCK        # AUDIT | BLOCK — what happens when a verdict IS reached
  failure_policy: Ignore    # KYVERNO ONLY — what happens when it CANNOT be reached
  kyverno: { version: "1.18" }   # KYVERNO ONLY — per cluster, env sets the default
exemptions:
  - name: k8s-pause                        # <=10 chars, unique per file
    image_value: "registry.k8s.io/pause"   # literal; no regex, no globs
    operator: starts_with                  # optional, KYVERNO-ONLY if not the default
    expired_at: "2026-11-15"               # optional, KYVERNO ONLY
    jiraTicketId: SEC-5678
    approved_by: security-team
```

`operator: equals` and `expired_at` are **rejected while `wiz` is in `tenants.yaml`'s
`backends`**, because a Wiz ignore rule aggregates a whole scope and carries exactly one
operator and one expiry. The gate is about capability, not prohibition: drop `wiz` from that
list — a reviewed, visible change — and both become legal. Each backend's workflow passes its
own `--backend`, so editing the list cannot switch off the gate for a backend still being
applied.

## Key decisions

1. **Signature-based compliance, manual exemptions**, on both backends. No compliant allowlist YAML, no compliance-bot, no auto-merge PR.
2. **NOTARY (Notation), not cosign.** Air-gapped + CA/X.509/private-key model.
3. **Wiz: one state per tenant.** The validator, every trust policy and every ignore rule share one state — which is what makes a *shared* env rule expressible at all.
4. **Wiz: exemptions are AGGREGATED** into at most two rules per cluster, because Wiz caps ignore rules per tenant. The price: prefix-only matching and no expiry.
5. **Kyverno: one `PolicyException` per entry.** No object cap, so per-entry expiry, operator, ticket and approver survive onto the object. The price is fan-out — an env-global entry is copied into every cluster in the env.
6. **Kyverno: an exception may reference only the catch-all policy.** Referencing the signature policy would let an exemption admit an *unsigned* self-built image shipped in the same pod.
7. **Kyverno: the exception guard covers the cluster's whole exemption set.** With a self-only guard, a pod containing two individually-exempt images matches neither exception and is denied. The cost is that adding one exemption re-renders every exception file in that cluster.
8. **`enforcement` and `failure_policy` are separate fields.** Fail-closed admission can stop every pod create in a cluster on a registry outage — a strictly larger blast radius than denying unsigned images — so it is chosen explicitly, not implied by `BLOCK`.
9. **Version pinning follows each backend's unit.** Wiz engine version per Wiz *tenant* (one apply covers a tenant); Kyverno version per *cluster* (a cluster is what gets upgraded). No flag day either way.
10. **Trust root in git, at the repo root** (`trust/*.crt`). A CA *certificate* is public; the CA *key* stays in an HSM. What needs protecting is **write authority**, and git + CODEOWNERS gives that a reviewable PR trail a secret store does not. A change here is in **both** workflows' path filters — without that, a reviewed CA could merge uninstalled.
11. **Rendered Kyverno manifests are committed**, and CI fails on drift. The manifest diff *is* the review artifact, and a hand-edit in the backend repo is caught rather than silently enforced.
12. **The image is one artifact, so `unikube.yaml` has no job matrix.** Build → compliance → push → sign each run once; only the exemption check loops over `target_clusters`.

## How a change flows

**Common mechanics.** A PR touching `unikube/exemptions/**`, `unikube/schemas/**`,
`unikube/scripts/**` or `trust/**` runs **both** backend workflows, independently:

- `terraform.yaml` — `validate.py --backend wiz` + tests, then one terraform job per Wiz tenant:
  `plan` on the PR, `plan`+`apply` on merge (nonprod, then gated prod). The PR comment carries
  real `tenant|ADD|CHANGE|DESTROY` counts read from the plan JSON.
- `kyverno.yaml` — `validate.py --backend kyverno` + tests, then `kyverno_render.py --check`
  (are the committed manifests exactly what the tree renders to?) and `kyverno_verify.sh` (will
  the version each cluster runs accept them?). The summary reports object counts and the
  fan-out multiplier — the number a reviewer needs: how many clusters this touches.

The use cases:

**1. Tenant admits a self-built image.** Call the reusable `unikube.yaml` (`image`, `tag`,
`target_clusters`). Once: build → `compliance_check.py` (every `FROM` on the approved registry +
post-build base-layer **digests** + freshness ≤ 30 days). Then:

- **Compliant** → push, then `image-signing/sign-image.sh` signs the pushed digest. Admitted
  fleet-wide by signature; `target_clusters` is not consulted at all.
- **Not compliant** → `check_exemption.py` runs for **every** entry in `target_clusters` against
  the merged exemptions, before any registry contact. All covered → push once, unsigned. Any
  uncovered → every uncovered cluster is reported and the run **fails red**, nothing pushed.
  All-or-nothing: one tag can't be admissible on some listed clusters and rejected on others.

**2. Add an exemption on one cluster.** Edit `unikube/exemptions/<env>/<cluster>.yaml` → PR →
security approval → merge. Wiz: an in-place update to that cluster's single ignore rule. Kyverno:
one new `PolicyException` file, plus a re-rendered guard clause in every other exception file for
that cluster (see decision 7).

**3. Env-wide exemption via `global.yaml`.** Wiz: touches the **one** shared `ignore-<env>-global`
rule; no cluster object changes. Kyverno: a new object in **every cluster directory in that env**
— the fan-out, visible in the diff rather than hidden.

**4. Onboard / offboard a cluster.** Add `<env>/<cluster>.yaml` → Wiz plan creates its trust
policy and rules; Kyverno renders a new directory. Delete it → Wiz **destroys** them (read the
DESTROY count in the PR comment); the Kyverno renderer deletes the files, and the sync layer must
**prune** the objects — a deleted file is not a deleted object.

**5. Roll out a new Wiz engine version.** Bump `nonprod` in `tenants.yaml` → verify → bump `prod`.
The tenant is the smallest unit a version can be rolled to.

**6. Move a cluster to Kyverno 1.19.** Set `admission.kyverno.version: "1.19"` in that cluster's
file, re-render, commit. One directory changes. `_preview-1.19/` already shows what the whole
fleet would look like.

**7. Rotate the signing leaf (routine, ~365 days).** Re-issue from the same CA, update the CI
secrets. **No terraform, no manifests, no PR** — `trust/ca.crt` is unchanged. Because signatures
are not timestamped, an expired leaf stops admitting: coarse fleet-wide revocation, which is why
the leaf is short-lived.

**8. Replace the CA trust root (rare).** Edit `trust/` → PR → security approval → merge. Wiz: one
in-place update of the shared validator, id stable, live fleet-wide at once. Kyverno: a diff in
every cluster directory. ⚠ Do it as **add-new → re-sign → remove-old**; Wiz's `notary_v2` takes a
list, and whether Kyverno's `certs.value` accepts multiple concatenated PEMs is **unverified**.

## Ownership (CODEOWNERS)

Security (`@org/security-leads`), platform (`@org/unikube-platform`), and customer teams who
co-own their cluster file. `CODEOWNERS`, `trust/`, and all `preprod/` + `prod/` changes require
security approval — `trust/` because a swapped CA cert would admit anything on every cluster on
both backends. There is no compliance-bot. `pck/` is out of scope.

## Follow-ups and open risks

**Highest severity, Kyverno:**

- **⚠ Do exceptions fire for Deployments?** A Deployment carries the pod spec at
  `spec.template.spec`. Whether Kyverno's autogen rewrites a *PolicyException's* `matchConditions`
  is unverified. The rendered CEL resolves the shape itself as belt-and-braces, but if autogen
  does not handle it and the mitigation were removed, **every vendor workload is denied on day
  one**. POC 5.12, extended to a Deployment, settles it.
- **⚠ Multi-PEM `certs.value`.** Blocks add-new → re-sign → remove-old CA rotation on the Kyverno
  side. Wiz has it via `notary_v2`'s list.
- **⚠ 1.19 is still an RC** (chart `3.9.0-rc.4`). The 1.19 tree is rendered and schema-validated;
  it should not be applied to anything that matters until GA. The per-cluster pin exists so
  "are we ready" is a one-line PR.
- **F4 on 1.18.2:** verification runs in the *mutating* webhook and is handed over in a pod
  annotation a caller could forge if mutate is bypassed. Nothing in the manifests mitigates it —
  it is an argument against `BLOCK` on 1.18.
- **Delivery is documented, not built.** Whatever syncs the manifests must prune, and must make
  partial convergence visible.

**Wiz:**

- **⚠ Shared ignore rules are unverified against the provider** — the design assumes one rule id
  can appear in multiple policies' `ignore_rules`. Confirm before the first real apply.
- **⚠ The ignore-rule cap is not encoded anywhere.** `ignore_rule_count` is the only signal.
- **Real state backend.** Wire S3 + DynamoDB for the two tenant states; watch plan times and
  lock contention at ~200 clusters in one state.

**Both:**

- **Signing is real but unexercised.** `sign-image.sh` invokes `notation` for real (file keys
  only) and expiry-checks the leaf, but has never run against a live registry in CI.
- **Leaf custody.** `trust/ca.crt` is settled. Where the signing **leaf** lives in CI — GitHub
  secrets vs. an HSM/KMS plugin — and who runs the annual re-issue, is not.
- **Revocation is a latent egress dependency.** Today's leaves carry no CDP/OCSP, so strict
  verification passes without egress. The day the PKI stamps them on, admission acquires a hard
  dependency on reaching that endpoint from inside every cluster, on the pod-create path.
- **The fail-open/fail-closed question (ADR-0002 open risk 1) is unanswered for BOTH backends.**
  POC P10/P12 answer it for Kyverno and produce the baseline to measure Wiz against.
