#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# lib.sh: paths and helpers shared by every script of the plugin. Source it:
#   . "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# Every absolute host path is prefixed with ${ROOT:-} so that the test suite
# can run the scripts against a fake root. The pinned versions come from
# gpu-unlock.env next to the plugin (a copy of the repository's versions.env),
# parsed with sed and never sourced.
#
# shellcheck disable=SC2034 # sourced library: its variables are read by the scripts that source it

[ -n "${GU_LIB_LOADED:-}" ] && return 0
GU_LIB_LOADED=1

PLUGIN=gpu-unlock
PLUGIN_TITLE="GPU Unlock"
ROOT=${ROOT:-}

FLASH_DIR="$ROOT/boot/config/plugins/$PLUGIN"
EMHTTP_DIR="$ROOT/usr/local/emhttp/plugins/$PLUGIN"
RUN_DIR="$ROOT/run/$PLUGIN"
MODPROBE_DIR="$ROOT/boot/config/modprobe.d"
MODPROBE_CONF="$MODPROBE_DIR/$PLUGIN.conf"
HOOK_SRC="$EMHTTP_DIR/hook/pre-nvidia.sh"
HOOK_DST="$FLASH_DIR/pre-nvidia.sh"
MODULES_DIR="$FLASH_DIR/modules"
FIRMWARE_DIR="$FLASH_DIR/firmware"
CFG_FILE="$FLASH_DIR/$PLUGIN.cfg"
ENV_FILE="$EMHTTP_DIR/$PLUGIN.env"
CRON_FILE="$FLASH_DIR/$PLUGIN.cron"
DISABLED_MARKER="$FLASH_DIR/disabled"
HOOK_STATUS="$RUN_DIR/hook.status"
FIRMWARE_LOG="$RUN_DIR/firmware.log"
FIRMWARE_PID="$RUN_DIR/firmware.pid"
NOTIFY_BIN="$ROOT/usr/local/emhttp/webGui/scripts/notify"
UPDATE_CRON_BIN="$ROOT/usr/local/sbin/update_cron"
CTL_BIN="$ROOT/usr/local/sbin/gpu-unlock-ctl"
BZIMAGE="$ROOT/boot/bzimage"
CMDLINE="$ROOT/proc/cmdline"
SYS_PCI="$ROOT/sys/bus/pci/devices"
# The rule the plugin installs; the hook path is the one on the real host, never prefixed.
# shellcheck disable=SC2016 # modprobe itself expands the CMDLINE_OPTS variable
HOOK_RULE='install nvidia /bin/sh /boot/config/plugins/gpu-unlock/pre-nvidia.sh; /sbin/modprobe --ignore-install nvidia $CMDLINE_OPTS'
RELEASE_BASE_DEFAULT=https://github.com/tabilzad/gpu-unlock-unraid/releases/download
RELEASES_PAGE=https://github.com/tabilzad/gpu-unlock-unraid/releases

# Test mode (GU_TEST_MODE=1) unlocks a few overrides production never honours;
# each is documented where it is read.
test_mode=0
[ "${GU_TEST_MODE:-0}" = 1 ] && test_mode=1

# env_get KEY: a pinned value from gpu-unlock.env (empty when missing).
env_get() {
  sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null | head -n1
}
# cfg_get KEY DEFAULT: a user setting from gpu-unlock.cfg, KEY="value" lines.
cfg_get() {
  local v
  v=$(sed -n "s/^$1=\"\\(.*\\)\"\$/\\1/p" "$CFG_FILE" 2>/dev/null | head -n1)
  printf '%s' "${v:-$2}"
}

MODULE_VERSION=$(env_get MODULE_VERSION)
NV=$(env_get NV)
UPSTREAM_REPO=$(env_get UPSTREAM_REPO)
UPSTREAM_REF=$(env_get UPSTREAM_REF)
# Device ids the module accepts (supported_ids in upstream main.c at UPSTREAM_REF).
SUPPORTED_IDS="2200 2203 2204 2205 2206 2207 2208 220a 220d 2216 222b 222f
2480 2482 2483 2484 2486 2487 2488 2489 248a 248c 248d 248e 249c 249d 249f 24a0
24a4 24ac 24ad 24af 24bf 24c0 24c7 24c8 24c9 24dc 24dd 24df 24e0
2414
2501 2503 2504 2505 2507 2508 2509 252f 2544
2520 2560"

# ---------------------------------------------------------------------------
# Logging and notifications
# ---------------------------------------------------------------------------

# log LEVEL MESSAGE...   LEVEL: info|notice|warning|err. Syslog plus stderr for problems.
log() {
  local level=$1
  shift
  logger -t "$PLUGIN" -p "user.$level" -- "${GU_SCRIPT_NAME:-${0##*/}}: $*" 2>/dev/null || true
  if [ "$level" = err ] || [ "$level" = warning ]; then
    printf '%s: %s\n' "$PLUGIN" "$*" >&2
  fi
}

# notify IMPORTANCE SUBJECT DESCRIPTION   IMPORTANCE: normal|warning|alert
notify() {
  local importance=$1 subject=$2 description=$3
  if [ -x "$NOTIFY_BIN" ]; then
    "$NOTIFY_BIN" -e "$PLUGIN_TITLE" -s "$subject" -d "$description" -i "$importance" >/dev/null 2>&1 || true
  fi
  log notice "notify [$importance] $subject: $description"
}

# notify_once KEY IMPORTANCE SUBJECT DESCRIPTION: at most once per boot (marker in /run).
notify_once() {
  local key=$1
  shift
  mkdir -p "$RUN_DIR" 2>/dev/null || true
  [ -e "$RUN_DIR/notified-$key" ] && return 0
  : >"$RUN_DIR/notified-$key" 2>/dev/null || true
  notify "$@"
}

# ---------------------------------------------------------------------------
# Kernels
# ---------------------------------------------------------------------------

running_kernel() {
  # GU_KVER: test suite only.
  if [ "$test_mode" = 1 ] && [ -n "${GU_KVER:-}" ]; then
    printf '%s' "$GU_KVER"
  else
    uname -r
  fi
}

# pending_kernel: the version of the kernel in /boot/bzimage, which is the one
# the next boot runs (an Unraid update replaces it before the reboot). Reads
# the bzImage setup header: "HdrS" at 0x202, and at 0x20E the offset of the
# version string, relative to 0x200. Empty output when unreadable.
pending_kernel() {
  local magic off ver
  [ -r "$BZIMAGE" ] || return 1
  magic=$(dd if="$BZIMAGE" bs=1 skip=514 count=4 2>/dev/null | tr -d '\0')
  [ "$magic" = HdrS ] || return 1
  off=$(od -An -tu2 -j 526 -N 2 "$BZIMAGE" 2>/dev/null | tr -d ' ')
  [[ "$off" =~ ^[0-9]+$ ]] && [ "$off" -gt 0 ] || return 1
  ver=$(dd if="$BZIMAGE" bs=1 skip=$((off + 512)) count=96 2>/dev/null | tr -d '\0' | sed -n '1s/^\([^ ]*\).*/\1/p')
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+[A-Za-z0-9._-]*$ ]] || return 1
  printf '%s' "$ver"
}

valid_kver() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+-Unraid$ ]]
}

# ---------------------------------------------------------------------------
# State on the flash drive and in this boot
# ---------------------------------------------------------------------------

module_path() {
  printf '%s' "$MODULES_DIR/$1/gpu_unlock.ko"
}

# module_ok KVER: the module for KVER is present, verified, and of the pinned version.
module_ok() {
  local dir="$MODULES_DIR/$1"
  [ -r "$dir/gpu_unlock.ko" ] && [ -r "$dir/SHA256SUMS" ] || return 1
  (cd "$dir" && sha256sum -c SHA256SUMS >/dev/null 2>&1) || return 1
  [ "$(sed -n 's/^module_version=//p' "$dir/manifest.txt" 2>/dev/null)" = "$MODULE_VERSION" ]
}

firmware_ok() {
  [ -r "$FIRMWARE_DIR/SHA256SUMS" ] && [ -d "$FIRMWARE_DIR/gpu-unlock/$NV" ] || return 1
  [ "$(cat "$FIRMWARE_DIR/VERSION" 2>/dev/null)" = "$NV" ] || return 1
  (cd "$FIRMWARE_DIR" && sha256sum -c SHA256SUMS >/dev/null 2>&1)
}

hook_installed() {
  [ -r "$MODPROBE_CONF" ] && grep -qxF "$HOOK_RULE" "$MODPROBE_CONF"
}

# hook_conflict: other files in modprobe.d carrying an install-nvidia rule.
hook_conflict() {
  grep -lE '^[[:space:]]*install[[:space:]]+nvidia[[:space:]]' "$MODPROBE_DIR"/*.conf 2>/dev/null |
    grep -vxF "$MODPROBE_CONF" || true
}

cmdline_targets() {
  local arg
  # shellcheck disable=SC2013 # the command line is one line of words
  for arg in $(cat "$CMDLINE" 2>/dev/null); do
    case "$arg" in
      gpu_unlock.targets=*) printf '%s' "${arg#gpu_unlock.targets=}" ;;
    esac
  done
}

safe_mode() {
  [ -f "$ROOT/boot/unraidsafemode" ] || grep -qw unraidsafemode "$CMDLINE" 2>/dev/null
}

module_loaded() {
  [ -d "$ROOT/sys/module/gpu_unlock" ]
}

# nvidia_cards: one line per NVIDIA display controller: ADDRESS DEVICE DRIVER SUPPORTED
nvidia_cards() {
  local dev vendor class device drv id supported
  for dev in "$SYS_PCI"/*; do
    [ -d "$dev" ] || continue
    vendor=$(cat "$dev/vendor" 2>/dev/null)
    [ "$vendor" = 0x10de ] || continue
    class=$(cat "$dev/class" 2>/dev/null)
    case "$class" in 0x0300* | 0x0302*) ;; *) continue ;; esac
    device=$(cat "$dev/device" 2>/dev/null)
    drv=$(basename "$(readlink "$dev/driver" 2>/dev/null)" 2>/dev/null)
    id=${device#0x}
    supported=no
    case " $(printf '%s' "$SUPPORTED_IDS" | tr '\n' ' ') " in *" $id "*) supported=yes ;; esac
    printf '%s %s %s %s\n' "$(basename "$dev")" "$device" "${drv:-none}" "$supported"
  done
}

# kernel_log_lines: what gpu_unlock and the nvidia load logged this boot.
kernel_log_lines() {
  if [ -n "$ROOT" ]; then
    grep -Ei 'gpu[-_]unlock|NVRM: loading' "$ROOT/var/log/dmesg" 2>/dev/null || true
  else
    dmesg 2>/dev/null | grep -Ei 'gpu[-_]unlock|NVRM: loading' || true
  fi
}

# atomic_write FILE MODE  (content on stdin)
atomic_write() {
  local file=$1 mode=$2 tmp
  mkdir -p "$(dirname "$file")"
  tmp=$(mktemp "$(dirname "$file")/.tmp.XXXXXX") || return 1
  cat >"$tmp" && chmod "$mode" "$tmp" 2>/dev/null
  mv -f "$tmp" "$file"
}

# plugin_version: the installed package's version, from the package database.
plugin_version() {
  local entry
  for entry in "$ROOT/var/lib/pkgtools/packages/$PLUGIN"-* "$ROOT/var/log/packages/$PLUGIN"-*; do
    [ -f "$entry" ] || continue
    entry=$(basename -- "$entry")
    entry=${entry#"$PLUGIN-"}
    printf '%s' "${entry%-noarch-*}"
    return 0
  done
  printf 'unknown'
}
