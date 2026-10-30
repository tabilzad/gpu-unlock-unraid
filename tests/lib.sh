#!/bin/bash
# tests/lib.sh: helpers for the plugin's test scripts. Source it.
#
# Every test runs the real scripts against a fake root (ROOT prefix, see
# scripts/lib.sh) with GU_TEST_MODE=1, a stub notify, a fake /proc/cmdline,
# fake PCI devices and a file:// release base.
# shellcheck disable=SC2034 # sourced library

REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# The pins the scripts under test read from gpu-unlock.env (a copy of versions.env).
MV=$(sed -n 's/^MODULE_VERSION=//p' "$REPO/versions.env")
NV=$(sed -n 's/^NV=//p' "$REPO/versions.env")
FW_FILES=$(sed -n 's/^FIRMWARE_FILES=//p' "$REPO/versions.env")
T_FAILS=0
T_COUNT=0

pass() {
  T_COUNT=$((T_COUNT + 1))
  echo "  ok   $1"
}
fail() {
  T_COUNT=$((T_COUNT + 1))
  T_FAILS=$((T_FAILS + 1))
  echo "  FAIL $1" >&2
}
# assert MSG CMD...: passes when CMD succeeds
assert() {
  local msg=$1
  shift
  if "$@"; then pass "$msg"; else fail "$msg"; fi
}
# assert_rc MSG EXPECTED CMD...
assert_rc() {
  local msg=$1 expected=$2 rc=0
  shift 2
  "$@" || rc=$?
  if [ "$rc" = "$expected" ]; then pass "$msg"; else fail "$msg (exit $rc, expected $expected)"; fi
}
# assert_grep MSG PATTERN FILE
assert_grep() {
  local msg=$1 pattern=$2 file=$3
  if grep -q -- "$pattern" "$file" 2>/dev/null; then
    pass "$msg"
  else
    fail "$msg (no '$pattern' in $file)"
    sed 's/^      /      /' "$file" 2>/dev/null | head -n 20 | sed 's/^/      | /' >&2
  fi
}
assert_not_grep() {
  local msg=$1 pattern=$2 file=$3
  if grep -q -- "$pattern" "$file" 2>/dev/null; then fail "$msg (found '$pattern' in $file)"; else pass "$msg"; fi
}
finish() {
  echo "$T_COUNT checks, $T_FAILS failed"
  [ "$T_FAILS" -eq 0 ]
}

# setup_root: a fake root with the package tree installed from src/.
setup_root() {
  ROOT=$(mktemp -d "${TMPDIR:-/tmp}/gu-test.XXXXXX")
  export ROOT GU_TEST_MODE=1
  mkdir -p "$ROOT"/{boot/config/plugins,boot/config/modprobe.d,proc,run,sys/bus/pci/devices,sys/module,lib/firmware,usr/local/emhttp/webGui/scripts,usr/local/sbin,var/log,tmp}
  cp -R "$REPO/src/." "$ROOT/"
  cp "$REPO/versions.env" "$ROOT/usr/local/emhttp/plugins/gpu-unlock/gpu-unlock.env"
  chmod +x "$ROOT"/usr/local/sbin/gpu-unlock-ctl "$ROOT"/usr/local/emhttp/plugins/gpu-unlock/scripts/* \
    "$ROOT"/usr/local/emhttp/plugins/gpu-unlock/hook/* "$ROOT"/usr/local/emhttp/plugins/gpu-unlock/docker/*.sh
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/notify.log"\n' "$ROOT" >"$ROOT/usr/local/emhttp/webGui/scripts/notify"
  chmod +x "$ROOT/usr/local/emhttp/webGui/scripts/notify"
  printf 'BOOT_IMAGE=/bzimage initrd=/bzroot\n' >"$ROOT/proc/cmdline"
  : >"$ROOT/var/log/dmesg"
}

set_cmdline() {
  printf 'BOOT_IMAGE=/bzimage initrd=/bzroot %s\n' "$*" >"$ROOT/proc/cmdline"
}

# fake_card ADDRESS DEVICE [DRIVER]
fake_card() {
  local d="$ROOT/sys/bus/pci/devices/$1"
  mkdir -p "$d"
  echo 0x10de >"$d/vendor"
  echo 0x030000 >"$d/class"
  echo "$2" >"$d/device"
  [ -z "${3:-}" ] || ln -sfn "../../../bus/pci/drivers/$3" "$d/driver"
}

# fake_bzimage VERSION: a file with a bzImage setup header naming VERSION.
fake_bzimage() {
  local f="$ROOT/boot/bzimage"
  head -c 1024 /dev/zero >"$f"
  printf 'HdrS' | dd of="$f" bs=1 seek=514 conv=notrunc 2>/dev/null
  printf '\000\001' | dd of="$f" bs=1 seek=526 conv=notrunc 2>/dev/null
  printf '%s (root@dev) #1 SMP PREEMPT_DYNAMIC Mon Jan 1 00:00:00 UTC 2026' "$1" | dd of="$f" bs=1 seek=768 conv=notrunc 2>/dev/null
}

# fake_release KVER [bad]: publish a module for KVER under a file:// release base.
fake_release() {
  local base="$ROOT/releases" dir name
  dir="$base/$1"
  name="gpu_unlock-$MV-$1"
  mkdir -p "$dir"
  if [ -s "$REPO/dist/modules/$name.ko" ]; then
    cp "$REPO/dist/modules/$name.ko" "$dir/$name.ko"
  else
    printf 'not a real module for %s\n' "$1" >"$dir/$name.ko"
  fi
  (cd "$dir" && sha256sum "$name.ko" >"$name.ko.sha256")
  [ "${2:-}" != bad ] || sed -i 's/^./0/' "$dir/$name.ko.sha256"
  printf 'kernel=%s\nmodule_version=%s\n' "$1" "$MV" >"$dir/$name.manifest.txt"
  mkdir -p "$ROOT/boot/config/plugins/gpu-unlock"
  printf 'RELEASE_BASE="file://%s"\n' "$base" >"$ROOT/boot/config/plugins/gpu-unlock/gpu-unlock.cfg"
}

# fake_firmware DIR [old]: random files laid out like the generator's output,
# the set versions.env lists; "old" makes the five-file set gpu_unlock 1.0.0
# loaded, as a flash drive from an earlier plugin carries it.
fake_firmware() {
  local dir=$1 f files=$FW_FILES
  [ "${2:-}" != old ] || files="booter_load_ga102.bin gsp_ga10x.bin gsp_boot_ga102.bin gsp_boot_desc_ga102.bin v67-ga102-610.43.03.bin"
  rm -rf "$dir/gpu-unlock"
  mkdir -p "$dir/gpu-unlock/$NV"
  for f in $files; do
    head -c 256 /dev/urandom >"$dir/gpu-unlock/$NV/$f"
  done
  echo "$NV" >"$dir/VERSION"
  # shellcheck disable=SC2094 # SHA256SUMS is excluded from the listing
  (cd "$dir" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS)
}

ctl() {
  "$ROOT/usr/local/sbin/gpu-unlock-ctl" "$@"
}
