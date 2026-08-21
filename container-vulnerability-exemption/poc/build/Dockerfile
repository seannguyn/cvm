FROM public.ecr.aws/docker/library/busybox:1.36
ARG VERSION=dev
RUN echo "$VERSION" > /version
CMD ["sh","-c","echo demo image v$(cat /version); sleep 604800"]
