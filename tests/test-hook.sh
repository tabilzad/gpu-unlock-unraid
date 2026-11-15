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
assert_grep "no targets: recorded" 'skipped: no cards chosen' "$STATUS"

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

echo "hook: targets from the settings file"
set_cmdline
printf '0000:01:00.0,0000:02:00.0\r\n' >"$FLASH/targets"
assert_rc "file targets: exit 0" 0 run_hook
assert_grep "file targets: used, CR stripped" 'targets=0000:01:00.0,0000:02:00.0 (from the settings page)' "$STATUS"
printf 'all\n' >"$FLASH/targets"
run_hook
assert_grep "file targets: all" 'targets=all (from the settings page)' "$STATUS"
printf 'rm -rf /; 0000:01:00.0\n' >"$FLASH/targets"
assert_rc "malformed file: exit 0" 0 run_hook
assert_grep "malformed file: skipped" 'skipped: malformed targets file' "$STATUS"
printf '0000:01:00.0\n' >"$FLASH/targets"
set_cmdline gpu_unlock.targets=0000:03:00.0
run_hook
assert_grep "command line overrides the file" 'targets=0000:03:00.0 (from the kernel command line)' "$STATUS"
rm -f "$FLASH/targets"
set_cmdline
run_hook
assert_grep "no targets anywhere: skipped" 'skipped: no cards chosen' "$STATUS"

echo "hook: a card the module kept is held back from the next boot"
fake_card 0000:01:00.0 0x2204 nvidia
fake_card 0000:02:00.0 0x1e07 nvidia
fake_card 0000:03:00.0 0x2487 nvidia
printf 'module_version=%s\n' "$MV" >"$FLASH/modules/$KVER/manifest.txt"
printf '#!/bin/sh\nexit 0\n' >"$ROOT/insmod-ok"
chmod +x "$ROOT/insmod-ok"
# run_ok: the hook with an insmod that succeeds, as on a server.
run_ok() {
  GPU_UNLOCK_INSMOD=$ROOT/insmod-ok GPU_UNLOCK_ROOT=$ROOT GPU_UNLOCK_KVER=$KVER /bin/sh "$HOOK" 2>"$ROOT/hook.err"
}
printf '0000:01:00.0,0000:03:00.0\n' >"$FLASH/targets"
cat >"$ROOT/var/log/dmesg" <<'EOF'
[   35.781138] pci 0000:03:00.0: gpu_unlock: failure unlock_transaction_fwsec:925 error=-19 family=TU102/TU104/TU106 payload=tu102-v67
[   35.801076] pci 0000:03:00.0: handover refused: incomplete transaction; BME_off=1 command=0x102 config_result=0; BAR ownership and DMA buffers retained until power off
[   35.830495] pci 0000:03:00.0: firmware did not stop; keeping its DMA buffers until power off
[   35.832772] pci 0000:03:00.0: gpu_unlock: unlock failed (-19)
[   35.900000] pci 0000:01:00.0: gpu_unlock: unlocked
EOF
assert_rc "kept card: exit 0" 0 run_ok
assert_grep "kept card: the status says so" 'the unlock kept 0000:03:00.0, held back from the next boot' "$STATUS"
assert "kept card: marker written" test -f "$FLASH/held/0000:03:00.0"
assert_grep "marker: module version" "^module_version=$MV\$" "$FLASH/held/0000:03:00.0"
assert_grep "marker: kernel" "^kernel=$KVER\$" "$FLASH/held/0000:03:00.0"
assert_grep "marker: reason" '^reason=unlock failed (-19); the module kept the card' "$FLASH/held/0000:03:00.0"
assert "the unlocked card has no marker" test ! -e "$FLASH/held/0000:01:00.0"
: >"$ROOT/var/log/dmesg"
run_ok
assert_grep "next boot: the held card is left out, and the status says so" 'targets=0000:01:00.0 (from the settings page; left alone: 0000:03:00.0); per-card result' "$STATUS"
printf 'all\n' >"$FLASH/targets"
run_ok
assert_grep "all: the cards present minus the held one" 'targets=0000:01:00.0,0000:02:00.0 (from the settings page; left alone: 0000:03:00.0)' "$STATUS"
printf 'module_version=9.9.9\nkernel=x\nreason=old\n' >"$FLASH/held/0000:03:00.0"
run_ok
assert_grep "a marker of another module version is stale: all stays all" 'targets=all (from the settings page)' "$STATUS"
assert "and the stale marker is gone" test ! -e "$FLASH/held/0000:03:00.0"

echo "hook: chips the module is known to fail on are left alone"
printf 'module_version=%s\nids=1e07 1e04\n' "$MV" >"$FLASH/known-bad"
run_ok
assert_grep "all: the known-bad card is left out" 'targets=0000:01:00.0,0000:03:00.0 (from the settings page; left alone: 0000:02:00.0)' "$STATUS"
printf '0000:02:00.0\n' >"$FLASH/targets"
run_ok
assert_grep "only a known-bad card chosen: skipped" 'skipped: every chosen card is held back or known to fail' "$STATUS"
printf 'module_version=0.0.1\nids=1e07\n' >"$FLASH/known-bad"
run_ok
assert_grep "a list for another module version is ignored" 'targets=0000:02:00.0 (from the settings page)' "$STATUS"
rm -f "$FLASH/known-bad" "$FLASH/targets"

rm -rf "$ROOT"
finish
