# Deliberately trivial — this demo is about SIGNING mechanics, not image content.
#
# NOTE: a real unikube image must be built FROM container-soe.registry.domain/* to pass the
# compliance check (see unikube/scripts/compliance_check.py). That check is out of scope here;
# this image exists only to have something with a digest to sign.
FROM alpine:3.20

# Changing VARIANT changes the layer, and therefore the DIGEST — which is how the tutorial gets
# two genuinely different images to sign with two different leaves. See README.md 1.6.
ARG VARIANT=a
RUN echo "venafi notation signing demo — variant ${VARIANT}" > /etc/demo-marker

ENTRYPOINT ["/bin/sh", "-c", "cat /etc/demo-marker && sleep infinity"]
