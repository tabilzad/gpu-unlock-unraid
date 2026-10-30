#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Entrypoint of the firmware generator image (Dockerfile next to this file). Runs upstream's own recipe:
#   make inputs     download the two NVIDIA inputs (the driver installer and the
#                   kernel module source), then checked here against the SHA-256
#                   pinned in the image (NV_INSTALLER_SHA256, NV_SOURCE_SHA256)
#   make firmware   generate the firmware files, every output checked by the generators
# and installs the result, the NVIDIA license and the upstream licenses into
# /out (mount the plugin's firmware directory there), with SHA256SUMS and
# VERSION for the boot hook. Mount a directory at /cache to keep the inputs
# between runs.
set -eu

OUT=${OUT:-/out}
CACHE=${CACHE:-/cache}
WORK=/work
NV=$(sed -n 's/^NV[[:space:]]*:=[[:space:]]*//p' /src/Makefile | head -n1)
[ -n "$NV" ] || { echo "firmware-gen: cannot read NV from the upstream Makefile" >&2; exit 1; }
# The files the module loads: FIRMWARE_FILES in the upstream Makefile, read
# by make itself (it is a backslash-continued list).
FILES=$(make -s -C /src -f - firmware-gen-files <<'MAKEFILE'
include /src/Makefile
firmware-gen-files:
	@echo $(FIRMWARE_FILES)
MAKEFILE
)
[ -n "$FILES" ] || { echo "firmware-gen: cannot read FIRMWARE_FILES from the upstream Makefile" >&2; exit 1; }
[ -n "${NV_INSTALLER_SHA256:-}" ] && [ -n "${NV_SOURCE_SHA256:-}" ] ||
    { echo "firmware-gen: NV_INSTALLER_SHA256 and NV_SOURCE_SHA256 are not set; build the image from the plugin's Dockerfile" >&2; exit 1; }
[ -d "$OUT" ] || { echo "firmware-gen: $OUT is not a directory; mount the output directory there" >&2; exit 1; }

echo "firmware-gen: gpu-unlock $(cat /src/VERSION), NVIDIA $NV, $(echo "$FILES" | wc -w) firmware files"
rm -rf "$WORK"
mkdir -p "$WORK" "$CACHE"
cd /src
make inputs INPUTS="$CACHE/inputs"
# Upstream's fetcher takes whatever the server sends; the pinned checksums
# decide. A file that does not match is removed so that the next run
# downloads it again.
check_input() { # SHA256 FILE
    if ! echo "$1  $CACHE/inputs/$2" | sha256sum -c - > /dev/null 2>&1; then
        echo "firmware-gen: $2 does not match its pinned SHA-256; removed, run again" >&2
        rm -f "$CACHE/inputs/$2"
        return 1
    fi
}
bad=0
check_input "$NV_INSTALLER_SHA256" "NVIDIA-Linux-x86_64-$NV-no-compat32.run" || bad=1
check_input "$NV_SOURCE_SHA256" "NVIDIA-kernel-module-source-$NV.tar.xz" || bad=1
[ "$bad" -eq 0 ] || exit 1
echo "firmware-gen: both inputs match their pinned SHA-256"
make firmware INPUTS="$CACHE/inputs" ASSETS="$WORK/assets"
make install-firmware ASSETS="$WORK/assets" DESTDIR="$WORK/out" FWDIR="/gpu-unlock/$NV" LICENSEDIR=/licenses
make install-licenses DESTDIR="$WORK/out" LICENSEDIR=/licenses PKG=gpu-unlock
cp /src/firmware/NOTICE.md "$WORK/out/licenses/"

cd "$WORK/out"
for f in $FILES; do
    [ -s "gpu-unlock/$NV/$f" ] || { echo "firmware-gen: $f was not generated" >&2; exit 1; }
done
n=$(find "gpu-unlock/$NV" -type f -name '*.bin' | wc -l)
[ "$n" -eq "$(echo "$FILES" | wc -w)" ] || { echo "firmware-gen: expected $(echo "$FILES" | wc -w) firmware files, found $n" >&2; exit 1; }
printf '%s\n' "$NV" > VERSION
# shellcheck disable=SC2094 # SHA256SUMS is excluded from the listing
find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS
sha256sum -c SHA256SUMS > /dev/null

# Replace the output atomically enough for a FAT32 flash drive: old files go
# only after the new set is complete and verified.
find "$OUT" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -R "$WORK/out/." "$OUT/"
(cd "$OUT" && sha256sum -c SHA256SUMS > /dev/null)
echo "firmware-gen: wrote $(du -sh "$OUT" | cut -f1) to $OUT:"
find "$OUT" -type f | sort
