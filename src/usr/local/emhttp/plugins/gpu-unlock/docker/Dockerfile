# SPDX-License-Identifier: GPL-2.0-only
#
# Generates the gpu-unlock firmware files on the Unraid host itself, with the
# generators from Zagitta/gpu-unlock at the pinned commit. The image holds
# only those GPL generators and their tools: the NVIDIA inputs (about 340 MB,
# checksummed by the generators) are downloaded when the container runs, and
# only the five generated files, the NVIDIA license and the checksums are
# written to /out. Nothing NVIDIA is ever redistributed by this plugin.
#
#   gpu-unlock-ctl firmware        builds this image and runs it (see firmware-gen.sh)
#   docker build -t gpu-unlock/firmware-gen /usr/local/emhttp/plugins/gpu-unlock/docker

ARG UPSTREAM_REPO=Zagitta/gpu-unlock
ARG UPSTREAM_REF=990a14e9b7dc8eaad8e6925133aa0e8382efe6cf

FROM python:3.12-alpine
ARG UPSTREAM_REPO
ARG UPSTREAM_REF
RUN apk add --no-cache coreutils make tar xz zstd curl ca-certificates
RUN set -eu; \
    curl -fsSL --retry 3 -o /tmp/upstream.tar.gz \
        "https://github.com/${UPSTREAM_REPO}/archive/${UPSTREAM_REF}.tar.gz"; \
    mkdir -p /src; tar -xzf /tmp/upstream.tar.gz -C /src --strip-components=1; \
    rm -f /tmp/upstream.tar.gz; \
    test -f /src/firmware/fetch_artifacts.py; test -f /src/firmware/generate_v67.py; \
    test -f /src/firmware/extract_boot_assets.py
COPY firmware-gen.sh /usr/local/bin/firmware-gen
RUN chmod 755 /usr/local/bin/firmware-gen
LABEL org.opencontainers.image.title="gpu-unlock firmware generator" \
      org.opencontainers.image.source="https://github.com/tabilzad/gpu-unlock-unraid" \
      org.opencontainers.image.licenses="GPL-2.0-only"
VOLUME ["/out"]
ENTRYPOINT ["/usr/local/bin/firmware-gen"]
