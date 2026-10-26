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
