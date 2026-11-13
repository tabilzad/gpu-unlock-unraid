#!/bin/bash
# Preview the settings page in a browser, without an Unraid server: the real
# page, endpoints and control tool run against a fake root, behind PHP's
# built-in web server (tests/helpers/preview-router.php). The buttons work:
# they change the fake root.
#
#   tests/preview.sh [SCENARIO] [PORT]      then open http://127.0.0.1:8088/
#
# SCENARIO: fresh      right after the install, nothing in place
#           ready      everything in place, before the first boot (default)
#           unlocked   after a boot that unlocked the chosen card
#           poweroff   a card reported that it needs a full power off
#           staged     an Unraid update is staged and its module is missing
#           firmware   a firmware generation is running (a simulation that
#                      walks through its phases in half a minute)
#
# On the host this starts itself inside the dev image with the port published
# on 127.0.0.1; inside the image (or wherever php is installed) it runs as is.
# Development only: the preview has no authentication.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

scenario=${1:-ready}
port=${2:-8088}
[[ "$port" =~ ^[0-9]+$ ]] || {
  echo "preview: the port must be a number" >&2
  exit 2
}

if [ -z "${IN_DEV_ENV:-}" ] && ! command -v php >/dev/null 2>&1; then
  echo "preview: starting inside the dev image; open http://127.0.0.1:$port/ (Ctrl-C stops it)"
  DEV_ENV_DOCKER_ARGS="-p 127.0.0.1:$port:$port" exec "$REPO/scripts/dev-env" --root bash tests/preview.sh "$scenario" "$port"
fi

setup_root
trap 'rm -rf "$ROOT"' EXIT
FLASH="$ROOT/boot/config/plugins/gpu-unlock"
RUN="$ROOT/run/gpu-unlock"
export GU_KVER=6.18.58-Unraid
mkdir -p "$ROOT/usr/share/hwdata" "$RUN" "$ROOT/sys/module/nvidia" "$ROOT/bin"
printf '10de  NVIDIA Corporation\n\t1e04  TU102 [GeForce RTX 2080 Ti]\n\t2204  GA102 [GeForce RTX 3090]\n\t2487  GA104 [GeForce RTX 3060]\n\t2d04  GB206 [GeForce RTX 5060 Ti]\n' >"$ROOT/usr/share/hwdata/pci.ids"
fake_card 0000:01:00.0 0x2204 nvidia
fake_card 0000:02:00.0 0x2487 vfio-pci
fake_card 0000:09:00.0 0x2d04 nvidia
# The preview has no Docker service: Generate firmware fails with that reason.
printf '#!/bin/sh\nexit 1\n' >"$ROOT/bin/docker"
chmod +x "$ROOT/bin/docker"
export PATH="$ROOT/bin:$PATH"

in_place() {
  ctl hook-install >/dev/null
  fake_release "$GU_KVER"
  ctl fetch >/dev/null
  fake_firmware "$FLASH/firmware"
  ctl targets set 0000:01:00.0 >/dev/null
}
booted() {
  printf 'loaded: gpu_unlock for %s, targets=0000:01:00.0 (from the settings page); per-card result in the kernel log\n' "$GU_KVER" >"$RUN/hook.status"
  mkdir -p "$ROOT/sys/module/gpu_unlock"
}

case "$scenario" in
  fresh) fake_release "$GU_KVER" ;;
  ready) in_place ;;
  unlocked)
    in_place
    booted
    printf '[   35.145140] gpu-unlock: loading gpu_unlock for %s with targets=0000:01:00.0 (from the settings page) before nvidia\n[   36.265856] pci 0000:01:00.0: gpu_unlock: unlocked\n[   36.404776] NVRM: loading NVIDIA UNIX Open Kernel Module for x86_64  580.196.07  Release Build\n' "$GU_KVER" >"$ROOT/var/log/dmesg"
    ;;
  poweroff)
    in_place
    booted
    printf '[   41.199010] pci 0000:01:00.0: card already initialised since power on (WPR2 enabled); power off first\n[   41.199020] pci 0000:01:00.0: gpu_unlock: unlock failed (-16)\n[   42.000000] NVRM: loading NVIDIA UNIX Open Kernel Module for x86_64  580.196.07  Release Build\n' >"$ROOT/var/log/dmesg"
    ;;
  staged)
    in_place
    fake_bzimage 6.18.60-Unraid
    fake_release 6.18.60-Unraid
    ;;
  firmware)
    in_place
    rm -rf "$FLASH/firmware"
    (
      log="$RUN/firmware.log"
      echo "building gpu-unlock/firmware-gen:$MV from /usr/local/emhttp/plugins/gpu-unlock/docker" >"$log"
      sleep 6
      echo "generating firmware $NV with gpu-unlock/firmware-gen:$MV (downloads about 370 MB of NVIDIA inputs, checked against their pinned checksums)" >>"$log"
      echo "firmware-gen: gpu-unlock $MV, NVIDIA $NV, 16 firmware files" >>"$log"
      sleep 8
      echo "firmware-gen: both inputs match their pinned SHA-256" >>"$log"
      sleep 8
      echo "firmware-gen: wrote 109M to /out:" >>"$log"
      sleep 4
      fake_firmware "$FLASH/firmware"
      echo "firmware $NV is on the flash drive: /boot/config/plugins/gpu-unlock/firmware" >>"$log"
      echo 0 >"$RUN/firmware.rc"
    ) &
    echo $! >"$RUN/firmware.pid"
    ;;
  *)
    echo "preview: unknown scenario '$scenario' (fresh, ready, unlocked, poweroff, staged, firmware)" >&2
    exit 2
    ;;
esac

echo "preview: scenario '$scenario' at http://127.0.0.1:$port/ (Ctrl-C stops it; add ?theme=white, azure or gray)"
# Inside the dev image the server has to listen on every address for the
# published port to reach it, and Docker publishes that port on the host's
# loopback only. Anywhere else it listens on loopback itself.
bind=127.0.0.1
[ -z "${IN_DEV_ENV:-}" ] || bind=0.0.0.0
php -S "$bind:$port" "$REPO/tests/helpers/preview-router.php"
