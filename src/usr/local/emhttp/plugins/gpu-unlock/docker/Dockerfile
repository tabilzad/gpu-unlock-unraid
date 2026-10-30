# SPDX-License-Identifier: GPL-2.0-only
#
# Generates the gpu-unlock firmware files on the Unraid host itself, with the
# generators from Zagitta/gpu-unlock at the pinned commit. The image holds
# only those GPL generators and their tools: the NVIDIA inputs (the driver
# installer and the kernel module source, about 370 MB, each checked against
# the SHA-256 pinned here) are downloaded when the container runs, and only
# the generated files, the NVIDIA license and the checksums are written to
# /out. Nothing NVIDIA is ever redistributed by this plugin.
#
#   gpu-unlock-ctl firmware        builds this image and runs it (see firmware-gen.sh)
#   docker build -t gpu-unlock/firmware-gen /usr/local/emhttp/plugins/gpu-unlock/docker

ARG UPSTREAM_REPO=Zagitta/gpu-unlock
ARG UPSTREAM_REF=0532473b4b105ed216948ed9c5aaeab0fa5c734f
# The pinned SHA-256 of the two inputs (versions.env); firmware-gen refuses
# anything else. Upstream's fetcher stopped checking what it downloads.
ARG NV_INSTALLER_SHA256=e084451db730a6df29d3d74f655749c4d236e3c945f7d94b5205e84318fe2f90
ARG NV_SOURCE_SHA256=7e118923c7a23edc36114d63273a46e3e04e9af98695a42203e7ac2dfe9fc1dc

FROM python:3.12-alpine
ARG UPSTREAM_REPO
ARG UPSTREAM_REF
ARG NV_INSTALLER_SHA256
ARG NV_SOURCE_SHA256
ENV NV_INSTALLER_SHA256=${NV_INSTALLER_SHA256} NV_SOURCE_SHA256=${NV_SOURCE_SHA256}
RUN apk add --no-cache coreutils make tar xz zstd curl ca-certificates
RUN set -eu; \
    curl -fsSL --retry 3 -o /tmp/upstream.tar.gz \
        "https://github.com/${UPSTREAM_REPO}/archive/${UPSTREAM_REF}.tar.gz"; \
    mkdir -p /src; tar -xzf /tmp/upstream.tar.gz -C /src --strip-components=1; \
    rm -f /tmp/upstream.tar.gz; \
    test -f /src/firmware/fetch_artifacts.py; test -f /src/firmware/extract_gsp.py; \
    test -f /src/firmware/extract_boot_assets.py
COPY firmware-gen.sh /usr/local/bin/firmware-gen
RUN chmod 755 /usr/local/bin/firmware-gen
LABEL org.opencontainers.image.title="gpu-unlock firmware generator" \
      org.opencontainers.image.source="https://github.com/tabilzad/gpu-unlock-unraid" \
      org.opencontainers.image.licenses="GPL-2.0-only"
VOLUME ["/out"]
ENTRYPOINT ["/usr/local/bin/firmware-gen"]
