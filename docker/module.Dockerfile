# SPDX-License-Identifier: GPL-2.0-only
#
# Builds gpu_unlock.ko from Zagitta/gpu-unlock (pinned commit) against one exact
# Unraid kernel, using the prepared source tree ich777 publishes for every
# Unraid release (https://github.com/ich777/unraid_kernel/releases). The only
# output is the module plus its checksum and a manifest; nothing here touches
# a GPU and nothing NVIDIA is downloaded.
#
#   scripts/build-module --kver 6.18.58-Unraid        # the normal way (caches the tree)
#
#   docker build -f docker/module.Dockerfile --target out --output type=local,dest=dist \
#       --build-arg KVER=6.18.58-Unraid --build-arg GCC_VERSION=14.2.0 .
#
# KVER is `uname -r` on the Unraid host. GCC_VERSION must be the compiler named
# by CONFIG_CC_VERSION_TEXT in the tree's .config (build-module reads it); the
# build refuses to continue otherwise and prints the right value.

ARG KVER=6.18.58-Unraid
ARG GCC_VERSION=14.2.0
ARG UPSTREAM_REPO=Zagitta/gpu-unlock
ARG UPSTREAM_REF=990a14e9b7dc8eaad8e6925133aa0e8382efe6cf
ARG MODULE_VERSION=1.0.0

FROM gcc:${GCC_VERSION} AS module
ARG KVER
ARG UPSTREAM_REPO
ARG UPSTREAM_REF
ARG MODULE_VERSION
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -q && apt-get install -qy --no-install-recommends \
        bc bison flex libelf-dev libssl-dev kmod xz-utils curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Upstream, pinned by full commit: the archive's content is that commit's tree.
RUN set -eu; \
    curl -fsSL --retry 3 -o /tmp/upstream.tar.gz \
        "https://github.com/${UPSTREAM_REPO}/archive/${UPSTREAM_REF}.tar.gz"; \
    mkdir -p /src; tar -xzf /tmp/upstream.tar.gz -C /src --strip-components=1; \
    rm -f /tmp/upstream.tar.gz; \
    [ "$(cat /src/VERSION)" = "${MODULE_VERSION}" ] \
        || { echo "upstream ${UPSTREAM_REF} is version $(cat /src/VERSION), not ${MODULE_VERSION}: update versions.env" >&2; exit 1; }; \
    grep -q "MODULE_VERSION(\"${MODULE_VERSION}\")" /src/kernel/gpu_unlock/main.c

# The prepared kernel tree: from the build context when scripts/build-module
# cached it there, otherwise downloaded now.
COPY docker/cache/ /cache/
RUN set -eu; \
    f="/cache/linux-${KVER}.tar.xz"; \
    if [ ! -f "$f" ]; then \
        curl -fsSL --retry 3 -o /tmp/linux.tar.xz \
            "https://github.com/ich777/unraid_kernel/releases/download/${KVER}/linux-${KVER}.tar.xz"; \
        f=/tmp/linux.tar.xz; \
    fi; \
    mkdir -p "/usr/src/linux-${KVER}"; \
    tar -xJf "$f" -C "/usr/src/linux-${KVER}"; \
    rm -rf /cache /tmp/linux.tar.xz
WORKDIR /usr/src/linux-${KVER}

# The tree's prebuilt host tools (modpost, fixdep) were linked against a newer
# glibc than this image has, so mrproper drops them and modules_prepare
# rebuilds them here; the config and Module.symvers are kept. The compiler
# must be the one the config was made with, or olddefconfig would silently
# re-evaluate the CONFIG_CC_* options.
RUN set -eu; \
    if [ ! -f .config ] && [ -f config ]; then cp config .config; fi; \
    test -f .config || { echo "no .config in the ${KVER} tree" >&2; exit 1; }; \
    test -s Module.symvers || { echo "no Module.symvers in the ${KVER} tree" >&2; exit 1; }; \
    grep -qx '# CONFIG_MODVERSIONS is not set' .config \
        || { echo "CONFIG_MODVERSIONS is on in ${KVER}; this recipe expects it off" >&2; exit 1; }; \
    want=$(sed -n 's/^CONFIG_CC_VERSION_TEXT=".*gcc (GCC) \([0-9][0-9.]*\).*"$/\1/p' .config); \
    have=$(gcc -dumpfullversion); \
    [ "$want" = "$have" ] || { echo "kernel ${KVER} was configured with gcc $want but this stage has gcc $have: rebuild with --build-arg GCC_VERSION=$want" >&2; exit 1; }; \
    cp .config /tmp/config; cp Module.symvers /tmp/Module.symvers; \
    [ ! -s System.map ] || cp System.map /tmp/System.map; \
    make -s mrproper; \
    cp /tmp/config .config; cp /tmp/Module.symvers Module.symvers; \
    make -s olddefconfig; \
    make -s -j"$(nproc)" modules_prepare; \
    rel=$(make -s --no-print-directory kernelrelease); \
    [ "$rel" = "${KVER}" ] || { echo "tree reports kernelrelease $rel, expected ${KVER}" >&2; exit 1; }

# With CONFIG_MODVERSIONS off nothing checks the module's imports at build
# time, so every undefined symbol must be one the kernel exports (System.map
# lists them as __ksymtab_<name>); otherwise insmod would fail at boot.
RUN set -eu; \
    make -C /src/kernel/gpu_unlock KDIR="/usr/src/linux-${KVER}"; \
    if [ -s /tmp/System.map ]; then \
        missing=$(nm -u /src/kernel/gpu_unlock/gpu_unlock.ko | awk '{print $2}' | while read -r sym; do \
            grep -q " __ksymtab_$sym\$" /tmp/System.map || echo "$sym"; done); \
        [ -z "$missing" ] || { echo "symbols not exported by ${KVER}: $missing" >&2; exit 1; }; \
        echo "imports: $(nm -u /src/kernel/gpu_unlock/gpu_unlock.ko | wc -l) symbols, all exported by ${KVER}"; \
    else \
        echo "no System.map in the tree; import check skipped" >&2; \
    fi; \
    name="gpu_unlock-${MODULE_VERSION}-${KVER}"; \
    mkdir -p /out; \
    install -m644 /src/kernel/gpu_unlock/gpu_unlock.ko "/out/$name.ko"; \
    vermagic=$(modinfo -F vermagic "/out/$name.ko"); \
    [ "${vermagic%% *}" = "${KVER}" ] || { echo "vermagic '$vermagic' is not ${KVER}" >&2; exit 1; }; \
    [ "$(modinfo -F version "/out/$name.ko")" = "${MODULE_VERSION}" ]; \
    printf 'kernel=%s\nvermagic=%s\nmodule_version=%s\nupstream=%s@%s\ncompiler=gcc-%s\nbuilt=%s\n' \
        "${KVER}" "$vermagic" "${MODULE_VERSION}" "${UPSTREAM_REPO}" "${UPSTREAM_REF}" \
        "$(gcc -dumpfullversion)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "/out/$name.manifest.txt"; \
    (cd /out && sha256sum "$name.ko" > "$name.ko.sha256"); \
    modinfo "/out/$name.ko"

FROM scratch AS out
COPY --from=module /out/ /
