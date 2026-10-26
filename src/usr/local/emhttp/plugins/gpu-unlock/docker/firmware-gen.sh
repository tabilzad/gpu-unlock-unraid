#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Entrypoint of the firmware generator image (Dockerfile next to this file). Runs upstream's own recipe:
#   make inputs     download the two pinned NVIDIA inputs, SHA-256 checked
#   make firmware   generate the five firmware files, every input and output checked
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
[ -d "$OUT" ] || { echo "firmware-gen: $OUT is not a directory; mount the output directory there" >&2; exit 1; }

echo "firmware-gen: gpu-unlock $(cat /src/VERSION), NVIDIA $NV"
rm -rf "$WORK"
mkdir -p "$WORK" "$CACHE"
cd /src
make inputs INPUTS="$CACHE/inputs"
make firmware INPUTS="$CACHE/inputs" ASSETS="$WORK/assets"
make install-firmware ASSETS="$WORK/assets" DESTDIR="$WORK/out" FWDIR="/gpu-unlock/$NV" LICENSEDIR=/licenses
make install-licenses DESTDIR="$WORK/out" LICENSEDIR=/licenses PKG=gpu-unlock
cp /src/firmware/NOTICE.md "$WORK/out/licenses/"

cd "$WORK/out"
n=$(find "gpu-unlock/$NV" -type f -name '*.bin' | wc -l)
[ "$n" -eq 5 ] || { echo "firmware-gen: expected 5 firmware files, found $n" >&2; exit 1; }
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
