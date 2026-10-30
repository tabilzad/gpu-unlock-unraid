#!/bin/bash
# gpu-unlock-ctl, post-install and remove against a fake root.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

setup_root
FLASH="$ROOT/boot/config/plugins/gpu-unlock"
CONF="$ROOT/boot/config/modprobe.d/gpu-unlock.conf"
# shellcheck disable=SC2016 # modprobe itself expands the CMDLINE_OPTS variable
RULE='install nvidia /bin/sh /boot/config/plugins/gpu-unlock/pre-nvidia.sh; /sbin/modprobe --ignore-install nvidia $CMDLINE_OPTS'
export GU_KVER=6.18.58-Unraid
fake_bzimage 6.18.60-Unraid
fake_card 0000:01:00.0 0x2208 nvidia
fake_card 0000:02:00.0 0x1234
out="$ROOT/out.txt"

echo "ctl: pending kernel from the bzImage header"
assert "pending-kernel reads the staged kernel" test "$(ctl pending-kernel)" = 6.18.60-Unraid
rm -f "$ROOT/boot/bzimage"
assert_rc "pending-kernel without a bzimage fails" 1 ctl pending-kernel
fake_bzimage 6.18.60-Unraid

echo "ctl: hook-install"
assert_rc "hook-install succeeds" 0 ctl hook-install
assert "rule written" test "$(cat "$CONF")" = "$RULE"
assert "hook copied to the flash drive" cmp -s "$FLASH/pre-nvidia.sh" "$REPO/src/usr/local/emhttp/plugins/gpu-unlock/hook/pre-nvidia.sh"
assert "hook copy is executable" test -x "$FLASH/pre-nvidia.sh"
assert_grep "cron job written" 'gpu-unlock-ctl check --quiet' "$FLASH/gpu-unlock.cron"
assert_rc "hook-install is idempotent" 0 ctl hook-install
rm -f "$CONF"
printf 'install nvidia /bin/true\n' >"$ROOT/boot/config/modprobe.d/other.conf"
assert_rc "conflicting rule: hook-install returns 1" 1 ctl hook-install
assert "conflicting rule: ours not written" test ! -e "$CONF"
assert_grep "conflicting rule: notified" 'conflicting modprobe rule' "$ROOT/notify.log"
rm -f "$ROOT/boot/config/modprobe.d/other.conf"
assert_rc "hook-install after the conflict is gone" 0 ctl hook-install

echo "ctl: fetch"
fake_release 6.18.58-Unraid
assert_rc "fetch the running kernel's module" 0 ctl fetch
assert "module on the flash drive" test -s "$FLASH/modules/6.18.58-Unraid/gpu_unlock.ko"
assert "SHA256SUMS verifies" bash -c "cd '$FLASH/modules/6.18.58-Unraid' && sha256sum -c SHA256SUMS > /dev/null"
assert_grep "manifest carries the module version" '^module_version=1.0.0$' "$FLASH/modules/6.18.58-Unraid/manifest.txt"
assert_grep "manifest carries the source" '^source=file://' "$FLASH/modules/6.18.58-Unraid/manifest.txt"
ctl fetch >"$out" 2>&1
assert_grep "second fetch is a no-op" 'already on the flash drive' "$out"
assert_rc "fetch --force downloads again" 0 ctl fetch --force
assert_rc "fetch of an unpublished kernel fails" 1 ctl fetch 6.18.99-Unraid
assert "unpublished kernel leaves nothing behind" test ! -e "$FLASH/modules/6.18.99-Unraid"
fake_release 6.18.61-Unraid bad
assert_rc "fetch with a wrong checksum fails" 1 ctl fetch 6.18.61-Unraid
assert "wrong checksum leaves nothing behind" test ! -e "$FLASH/modules/6.18.61-Unraid"
assert_rc "fetch rejects a non-Unraid version" 1 ctl fetch 6.18.61
printf 'module_version=0.9.0\n' >"$FLASH/modules/6.18.58-Unraid/manifest.txt"
(cd "$FLASH/modules/6.18.58-Unraid" && sha256sum gpu_unlock.ko manifest.txt >SHA256SUMS)
ctl fetch >"$out" 2>&1
assert_grep "an older module version is replaced" 'installed module 1.0.0' "$out"

echo "ctl: check"
fake_release 6.18.60-Unraid
: >"$ROOT/notify.log"
assert_rc "check: firmware missing counts as a problem" 1 ctl check
assert "check fetched the staged kernel's module" test -s "$FLASH/modules/6.18.60-Unraid/gpu_unlock.ko"
assert_grep "check notified about the staged kernel" 'ready for kernel 6.18.60-Unraid' "$ROOT/notify.log"
assert_grep "check notified about missing firmware" 'firmware not generated' "$ROOT/notify.log"
fake_firmware "$FLASH/firmware"
assert_rc "check --quiet with everything present" 0 ctl check --quiet
fake_bzimage 6.18.70-Unraid
: >"$ROOT/notify.log"
assert_rc "check with an unpublished staged kernel fails" 1 ctl check --quiet
assert "warned once" test "$(grep -c 'no module for kernel 6.18.70-Unraid' "$ROOT/notify.log")" = 1
ctl check --quiet >/dev/null 2>&1
assert "not warned again this boot" test "$(grep -c 'no module for kernel 6.18.70-Unraid' "$ROOT/notify.log")" = 1

echo "ctl: status"
set_cmdline gpu_unlock.targets=0000:01:00.0
printf '[    5.0] pci 0000:01:00.0: gpu_unlock: unlocked\n[    6.0] NVRM: loading NVIDIA UNIX Open Kernel Module\n' >"$ROOT/var/log/dmesg"
ctl status --json >"$out" 2>"$ROOT/err.txt"
assert_rc "status --json is valid JSON" 0 python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$out"
check_json() {
  python3 - "$out" "$1" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
expr = sys.argv[2]
sys.exit(0 if eval(expr) else 1)
EOF
}
assert "json: kernel" check_json 'd["kernel"] == "6.18.58-Unraid"'
assert "json: pending kernel" check_json 'd["pending_kernel"] == "6.18.70-Unraid"'
assert "json: module present" check_json 'd["module_present"] is True'
assert "json: pending module absent" check_json 'd["pending_module_present"] is False'
assert "json: firmware present" check_json 'd["firmware_present"] is True'
assert "json: hook installed" check_json 'd["hook_installed"] is True and d["hook_conflict"] == ""'
assert "json: targets" check_json 'd["targets"] == "0000:01:00.0"'
assert "json: cards with support flag" check_json 'sorted((c["address"], c["supported"], c["driver"]) for c in d["cards"]) == [("0000:01:00.0", True, "nvidia"), ("0000:02:00.0", False, "none")]'
assert "json: kernel log lines" check_json 'any("gpu_unlock: unlocked" in l for l in d["kernel_log"])'
assert "json: modules list" check_json 'sorted(m["kernel"] for m in d["modules"]) == ["6.18.58-Unraid", "6.18.60-Unraid"] and all(m["ok"] for m in d["modules"])'
ctl status >"$out" 2>&1
assert_rc "status text runs" 0 ctl status
assert_grep "status text lists the card" '0000:01:00.0  device=0x2208  driver=nvidia  supported=yes' "$out"
assert_grep "status text shows the staged kernel" 'staged kernel:  6.18.70-Unraid' "$out"
assert_grep "status text: a missing hook record is explained" 'expected until the next boot' "$out"

echo "ctl: enable/disable"
assert_rc "disable" 0 ctl disable
assert "marker written" test -e "$FLASH/disabled"
assert "json: disabled" bash -c "'$ROOT/usr/local/sbin/gpu-unlock-ctl' status --json | grep -q '\"disabled\":true'"
assert_rc "enable" 0 ctl enable
assert "marker gone" test ! -e "$FLASH/disabled"

echo "ctl: firmware import"
fake_firmware "$ROOT/elsewhere"
rm -rf "$FLASH/firmware"
assert_rc "firmware import" 0 ctl firmware import "$ROOT/elsewhere"
assert "imported firmware verifies" bash -c "cd '$FLASH/firmware' && sha256sum -c SHA256SUMS > /dev/null"
rm -f "$ROOT/elsewhere/gpu-unlock/610.43.03/gsp_ga10x.bin"
assert_rc "firmware import refuses an incomplete set" 1 ctl firmware import "$ROOT/elsewhere"
assert "incomplete import left the old firmware alone" test -s "$FLASH/firmware/gpu-unlock/610.43.03/gsp_ga10x.bin"

echo "ctl: targets"
set_cmdline
assert "no targets: source none" bash -c "'$ROOT/usr/local/sbin/gpu-unlock-ctl' status --json | grep -q '\"targets_source\":\"none\"'"
assert_rc "targets set: one supported card" 0 ctl targets set 0000:01:00.0
assert "targets file written" test "$(cat "$FLASH/targets")" = 0000:01:00.0
assert_rc "targets set: unsupported card refused" 1 ctl targets set 0000:02:00.0
assert_rc "targets set: absent card refused" 1 ctl targets set 0000:09:00.0
assert_rc "targets set: garbage refused" 1 ctl targets set 'all;reboot'
assert "refusals leave the file alone" test "$(cat "$FLASH/targets")" = 0000:01:00.0
assert_rc "targets set all" 0 ctl targets set all
ctl targets >"$out"
assert_grep "targets show: from the file" '^all (from ' "$out"
ctl status --json >"$out"
assert "json: targets from the file" check_json 'd["targets"] == "all" and d["targets_source"] == "file"'
set_cmdline gpu_unlock.targets=0000:01:00.0
ctl status --json >"$out"
assert "json: command line overrides" check_json 'd["targets"] == "0000:01:00.0" and d["targets_source"] == "cmdline"'
set_cmdline
assert_rc "targets clear" 0 ctl targets clear
assert "targets file gone" test ! -e "$FLASH/targets"

echo "ctl: per-card verdicts and the boot report"
fake_card 0000:03:00.0 0x2204
ctl targets set all >/dev/null
printf 'loaded: gpu_unlock for 6.18.58-Unraid\n' >"$ROOT/run/gpu-unlock/hook.status"
cat >"$ROOT/var/log/dmesg" <<'EOF'
[   41.198220] gpu_unlock: failure kernel/gpu_unlock/unlock_610.c:1309 unlock_transaction_reset error=-5
[   41.198301] pci 0000:03:00.0: firmware did not stop; keeping its DMA buffers until power off
[   41.198305] pci 0000:03:00.0: gpu_unlock: unlock failed (-5)
[   41.201337] pci 0000:01:00.0: gpu_unlock: unlocked
[   42.000000] NVRM: loading NVIDIA UNIX Open Kernel Module for x86_64  615.78.08
EOF
ctl status --json >"$out"
assert "json: unlocked verdict" check_json 'any(v["address"] == "0000:01:00.0" and v["state"] == "unlocked" and v["power_off"] is False for v in d["verdicts"])'
assert "json: power-off verdict with reason" check_json 'any(v["address"] == "0000:03:00.0" and v["state"] == "failed" and v["power_off"] is True and "until power off" in v["reason"] for v in d["verdicts"])'
assert "json: power_off_required" check_json 'd["power_off_required"] is True'
: >"$ROOT/notify.log"
rm -f "$ROOT/run/gpu-unlock/notified-report"
assert_rc "report" 0 ctl report
assert_grep "report: alert on power off" 'power off required' "$ROOT/notify.log"
ctl report >/dev/null
assert "report: once per boot" test "$(grep -c 'power off required' "$ROOT/notify.log")" = 1
cat >"$ROOT/var/log/dmesg" <<'EOF'
[   41.199010] pci 0000:03:00.0: card already initialised since power on (WPR2 enabled); power off first
[   41.199020] pci 0000:03:00.0: gpu_unlock: unlock failed (-16)
[   41.201337] pci 0000:01:00.0: gpu_unlock: unlocked
EOF
ctl status --json >"$out"
assert "json: WPR2 verdict" check_json 'any(v["address"] == "0000:03:00.0" and v["power_off"] is True and "WPR2" in v["reason"] for v in d["verdicts"])'
cat >"$ROOT/var/log/dmesg" <<'EOF'
[   41.101000] pci 0000:03:00.0: Direct firmware load for gpu-unlock/610.43.03/gsp_ga10x.bin failed with error -2
[   41.101010] pci 0000:03:00.0: gpu_unlock: firmware load failed (-2)
[   41.201337] pci 0000:01:00.0: gpu_unlock: unlocked
EOF
ctl status --json >"$out"
assert "json: firmware failure verdict" check_json 'any(v["address"] == "0000:03:00.0" and v["state"] == "failed" and v["reason"] == "firmware load failed (-2)" and v["power_off"] is False for v in d["verdicts"])'
assert "json: no power off this time" check_json 'd["power_off_required"] is False'
: >"$ROOT/notify.log"
rm -f "$ROOT/run/gpu-unlock/notified-report"
ctl report >/dev/null
assert_grep "report: warning on failure" '1 card(s) failed to unlock' "$ROOT/notify.log"
printf '[   41.201337] pci 0000:01:00.0: gpu_unlock: unlocked\n[   41.201400] pci 0000:03:00.0: gpu_unlock: unlocked\n' >"$ROOT/var/log/dmesg"
: >"$ROOT/notify.log"
rm -f "$ROOT/run/gpu-unlock/notified-report"
ctl report >/dev/null
assert_grep "report: success notification" '2 card(s) unlocked' "$ROOT/notify.log"
ctl status >"$out"
assert_grep "status text: verdict line" '0000:03:00.0: unlocked' "$out"
printf 'skipped: no cards chosen\n' >"$ROOT/run/gpu-unlock/hook.status"
: >"$ROOT/notify.log"
rm -f "$ROOT/run/gpu-unlock/notified-report"
ctl report >/dev/null
assert "report: silent when the hook did not load" test ! -s "$ROOT/notify.log"

echo "ctl: a card held by another driver, and verdicts once the ring buffer forgot the boot"
fake_card 0000:04:00.0 0x2206 vfio-pci
ctl targets set all >/dev/null
printf 'loaded: gpu_unlock for 6.18.58-Unraid\n' >"$ROOT/run/gpu-unlock/hook.status"
cat >"$ROOT/var/log/dmesg" <<'EOF2'
[   41.201337] pci 0000:01:00.0: gpu_unlock: unlocked
[   41.201400] pci 0000:03:00.0: gpu_unlock: unlocked
[   41.201500] pci 0000:04:00.0: gpu_unlock: unlock failed (-16)
EOF2
ctl status --json >"$out"
assert "json: a driver-bound card is skipped, not failed" check_json 'any(v["address"] == "0000:04:00.0" and v["state"] == "skipped" and "vfio-pci" in v["reason"] and v["power_off"] is False for v in d["verdicts"])'
: >"$ROOT/notify.log"
rm -f "$ROOT/run/gpu-unlock/notified-report" "$ROOT/run/gpu-unlock/kernel.log"
ctl report >/dev/null
assert_grep "report: the skipped card does not spoil the success notification" '2 card(s) unlocked' "$ROOT/notify.log"
assert_not_grep "report: no failure warning for the skipped card" 'failed to unlock' "$ROOT/notify.log"
assert "report: kernel log lines kept in /run" test -s "$ROOT/run/gpu-unlock/kernel.log"
: >"$ROOT/var/log/dmesg"
ctl status --json >"$out"
assert "json: verdicts survive an empty ring buffer" check_json 'any(v["address"] == "0000:01:00.0" and v["state"] == "unlocked" for v in d["verdicts"])'
assert "json: the kernel log comes from the kept copy" check_json 'any("gpu_unlock: unlocked" in l for l in d["kernel_log"])'
printf '[   41.201500] pci 0000:03:00.0: gpu_unlock: unlock failed (-16)\n' >"$ROOT/var/log/dmesg"
ctl status --json >"$out"
assert "json: -16 on a card without a driver stays a failure" check_json 'any(v["address"] == "0000:03:00.0" and v["state"] == "failed" and v["reason"] == "unlock failed (-16)" for v in d["verdicts"])'
rm -rf "$ROOT/sys/bus/pci/devices/0000:04:00.0" "$ROOT/run/gpu-unlock/kernel.log"
ctl targets set 0000:01:00.0 >/dev/null
printf '[    5.0] pci 0000:01:00.0: gpu_unlock: unlocked\n[    6.0] NVRM: loading NVIDIA UNIX Open Kernel Module\n' >"$ROOT/var/log/dmesg"
set_cmdline gpu_unlock.targets=0000:01:00.0

echo "post-install and remove"
"$ROOT/usr/local/emhttp/plugins/gpu-unlock/scripts/post-install" >"$out" 2>&1
assert_rc "post-install exits 0" 0 "$ROOT/usr/local/emhttp/plugins/gpu-unlock/scripts/post-install"
assert_grep "post-install summary: module" 'module 1.0.0 for 6.18.58-Unraid: on the flash drive' "$out"
assert_grep "post-install summary: firmware" 'firmware 610.43.03: on the flash drive' "$out"
assert_grep "post-install summary: targets" 'targets: 0000:01:00.0' "$out"
"$ROOT/usr/local/emhttp/plugins/gpu-unlock/scripts/remove" >"$out" 2>&1
assert "remove: rule gone" test ! -e "$CONF"
assert "remove: modules gone" test ! -e "$FLASH/modules"
assert "remove: hook copy gone" test ! -e "$FLASH/pre-nvidia.sh"
assert "remove: cron gone" test ! -e "$FLASH/gpu-unlock.cron"
assert "remove: firmware kept" test -s "$FLASH/firmware/gpu-unlock/610.43.03/gsp_ga10x.bin"
assert "remove: settings kept" test -s "$FLASH/gpu-unlock.cfg"
assert "remove: RAM side gone" test ! -e "$ROOT/usr/local/emhttp/plugins/gpu-unlock" -a ! -e "$ROOT/usr/local/sbin/gpu-unlock-ctl"
assert_grep "remove: tells what was kept" 'Kept, because they are yours' "$out"

echo "uninstall --purge"
rm -rf "$ROOT"
setup_root
export GU_KVER=6.18.58-Unraid
FLASH="$ROOT/boot/config/plugins/gpu-unlock"
CONF="$ROOT/boot/config/modprobe.d/gpu-unlock.conf"
ctl hook-install >/dev/null
fake_firmware "$FLASH/firmware"
assert_rc "uninstall --purge" 0 ctl uninstall --purge
assert "purge removed the plugin directory" test ! -e "$FLASH"
assert "purge removed the rule" test ! -e "$CONF"

rm -rf "$ROOT"
finish
