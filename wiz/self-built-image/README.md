# self-built-image (mock tenant repo)

A stand-in for a tenant's application repo, used to exercise the unikube **compliance**
flow end to end.

- `Dockerfile` — alpine + `sleep`, built `FROM container-soe.registry.domain/alpine:3.20`
  (the approved base registry), so it is **compliant by construction**.
- `.github/workflows/deploy.yaml` — calls the shared reusable workflow
  `org/container-vulnerability-exemption/.github/workflows/unikube.yaml` with a list of
  `target_clusters`.

## What happens

On push, the shared workflow:
1. checks every `FROM` is on `container-soe.registry.domain/*` (fail fast if not),
2. builds, then verifies the actual base-layer **digests** + freshness (≤ 30 days) —
   it trusts digests, never `LABEL`s,
3. signs + attests the image (cosign/SLSA — stubbed in the mock),
4. runs an informational Wiz scan (AUDIT, never blocks), no `wiz tag`,
5. opens an **auto-merged** PR into `container-vulnerability-exemption` adding this exact
   image to each target cluster's `<env>/<cluster>.compliant.yaml`, with provenance.

If the base image were **not** on the approved registry, the workflow fails and asks you
to raise a **manual exemption** PR (which requires security approval).

See `container-vulnerability-exemption/wiz/project_metadata/image-signing-101.md` for the
cosign / attestation / image-label background.
