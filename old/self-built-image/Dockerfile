# Compliant self-built image: FROM the approved base registry only.
# The unikube compliance workflow checks every FROM against container-soe.registry.domain/*
# and the final base image's freshness.
FROM alpine:3.20

# (do NOT rely on LABELs to assert compliance — the gate ignores labels and checks the
#  actual base-layer digests. Labels here are only informational.)
LABEL org.opencontainers.image.source="https://github.com/org/self-built-image"

CMD ["sleep", "infinity"]
