#!/bin/bash
# The boot hook against a fake root: every skip path, the firmware staging,
# and that it never fails the nvidia load.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

setup_root
FLASH="$ROOT/boot/config/plugins/gpu-unlock"
HOOK="$FLASH/pre-nvidia.sh"
STATUS="$ROOT/run/gpu-unlock/hook.status"
KVER=6.18.58-Unraid
mkdir -p "$FLASH"
cp "$REPO/src/usr/local/emhttp/plugins/gpu-unlock/hook/pre-nvidia.sh" "$HOOK"

run_hook() {
  GPU_UNLOCK_ROOT=$ROOT GPU_UNLOCK_KVER=$KVER /bin/sh "$HOOK" 2>"$ROOT/hook.err"
}

echo "hook: opt-in and skip paths"
assert_rc "no targets: exit 0" 0 run_hook
assert_grep "no targets: recorded" 'skipped: no gpu_unlock.targets=' "$STATUS"

set_cmdline gpu_unlock.targets=0000:01:00.0
: >"$FLASH/disabled"
assert_rc "disabled: exit 0" 0 run_hook
assert_grep "disabled: recorded" 'skipped: disabled' "$STATUS"
rm -f "$FLASH/disabled"

set_cmdline gpu_unlock.targets=0000:01:00.0 unraidsafemode
assert_rc "safe mode: exit 0" 0 run_hook
assert_grep "safe mode: recorded" 'skipped: Safe Mode' "$STATUS"
set_cmdline gpu_unlock.targets=0000:01:00.0

assert_rc "no module: exit 0" 0 run_hook
assert_grep "no module: recorded" "skipped: no module for kernel $KVER" "$STATUS"

echo "hook: module and firmware checks"
mkdir -p "$FLASH/modules/$KVER"
printf 'not a module\n' >"$FLASH/modules/$KVER/gpu_unlock.ko"
printf '%064d  gpu_unlock.ko\n' 0 >"$FLASH/modules/$KVER/SHA256SUMS"
assert_rc "bad checksum: exit 0" 0 run_hook
assert_grep "bad checksum: recorded" 'skipped: checksum mismatch' "$STATUS"

(cd "$FLASH/modules/$KVER" && sha256sum gpu_unlock.ko >SHA256SUMS)
assert_rc "no firmware: exit 0" 0 run_hook
assert_grep "no firmware: recorded" 'skipped: no firmware' "$STATUS"

fake_firmware "$FLASH/firmware"
head -c 10 /dev/urandom >>"$FLASH/firmware/gpu-unlock/610.43.03/gsp_ga10x.bin"
assert_rc "firmware checksum mismatch: exit 0" 0 run_hook
assert_grep "firmware checksum mismatch: recorded" 'skipped: firmware checksum mismatch' "$STATUS"
assert "firmware not staged on mismatch" test ! -d "$ROOT/lib/firmware/gpu-unlock"

echo "hook: the load attempt"
fake_firmware "$FLASH/firmware"
assert_rc "insmod attempt: exit 0 even though insmod fails here" 0 run_hook
assert_grep "insmod attempt: recorded" 'failed: insmod' "$STATUS"
assert "firmware staged into lib/firmware" test -s "$ROOT/lib/firmware/gpu-unlock/610.43.03/gsp_ga10x.bin"
assert_grep "insmod error captured for the log" 'insmod' "$ROOT/run/gpu-unlock/hook.err"

mkdir -p "$ROOT/sys/module/gpu_unlock"
printf 'previous\n' >"$STATUS"
assert_rc "already loaded: exit 0" 0 run_hook
assert_grep "already loaded: status untouched" '^previous$' "$STATUS"
rmdir "$ROOT/sys/module/gpu_unlock"

echo "hook: concurrent invocations (flock)"
run_hook &
run_hook &
wait
assert "both concurrent runs finished" test -s "$STATUS"

rm -rf "$ROOT"
finish
