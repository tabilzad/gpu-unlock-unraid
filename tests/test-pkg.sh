#!/bin/bash
# The package: layout, modes, install and removal with Slackware's pkgtools,
# the rendered plg and its lint.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/gu-pkg.XXXXXX")
root="$tmp/root"
mkdir -p "$root"

echo "package: build"
txz=$("$REPO/scripts/build-txz" --version 0000.00.00.0-dev --out-dir "$tmp/dist")
assert "build-txz produced a package" test -s "$txz"
assert "package name" test "$(basename "$txz")" = gpu-unlock-0000.00.00.0_dev-noarch-1.txz
listing=$(tar -tvJf "$txz")
assert "first entry is ./" bash -c "printf '%s\n' \"\$1\" | head -n1 | grep -q ' \./\$'" _ "$listing"
assert "control tool is executable" bash -c "printf '%s\n' \"\$1\" | grep -q '^-rwxr-xr-x .* usr/local/sbin/gpu-unlock-ctl\$'" _ "$listing"
assert "hook is executable" bash -c "printf '%s\n' \"\$1\" | grep -q '^-rwxr-xr-x .* usr/local/emhttp/plugins/gpu-unlock/hook/pre-nvidia.sh\$'" _ "$listing"
assert "env file is packaged" bash -c "printf '%s\n' \"\$1\" | grep -q ' usr/local/emhttp/plugins/gpu-unlock/gpu-unlock.env\$'" _ "$listing"
assert "slack-desc is packaged" bash -c "printf '%s\n' \"\$1\" | grep -q ' install/slack-desc\$'" _ "$listing"
assert "page is packaged" bash -c "printf '%s\n' \"\$1\" | grep -q ' usr/local/emhttp/plugins/gpu-unlock/GpuUnlock.page\$'" _ "$listing"
txz2=$("$REPO/scripts/build-txz" --version 0000.00.00.0-dev --out-dir "$tmp/dist2")
assert "build is reproducible" cmp -s "$txz" "$txz2"

if command -v installpkg >/dev/null 2>&1; then
  echo "package: installpkg / removepkg into a fake root"
  assert_rc "installpkg" 0 bash -c "ROOT='$root' installpkg '$txz' > '$tmp/installpkg.log' 2>&1"
  assert "installed: control tool" test -x "$root/usr/local/sbin/gpu-unlock-ctl"
  assert "installed: env file" test -s "$root/usr/local/emhttp/plugins/gpu-unlock/gpu-unlock.env"
  assert "installed: page" test -s "$root/usr/local/emhttp/plugins/gpu-unlock/GpuUnlock.page"
  assert "installed: package database entry" bash -c "ls '$root'/var/lib/pkgtools/packages/gpu-unlock-* '$root'/var/log/packages/gpu-unlock-* 2>/dev/null | grep -q ."
  assert "installed tool runs from the fake root" bash -c "GU_TEST_MODE=1 GU_KVER=6.18.58-Unraid ROOT='$root' '$root/usr/local/sbin/gpu-unlock-ctl' status > /dev/null"
  assert_rc "removepkg" 0 bash -c "ROOT='$root' removepkg gpu-unlock > '$tmp/removepkg.log' 2>&1"
  assert "removed: control tool" test ! -e "$root/usr/local/sbin/gpu-unlock-ctl"
  assert "removed: plugin directory" test ! -e "$root/usr/local/emhttp/plugins/gpu-unlock/GpuUnlock.page"
else
  echo "package: pkgtools not installed, install test skipped"
fi

echo "plg: render and lint"
plg=$("$REPO/scripts/render-plg" --version 0000.00.00.0-dev --plugin-version 0.0.0-dev --txz "$txz" --out "$tmp/gpu-unlock.plg")
assert "render-plg wrote the plg" test -s "$plg"
assert_rc "xmllint accepts it" 0 xmllint --noent --noout "$plg"
assert_rc "lint-plg accepts it" 0 "$REPO/scripts/lint-plg" "$plg"
assert_grep "plg carries the package sha256" "$(cut -d' ' -f1 "$txz.sha256")" "$plg"
assert_grep "plg carries the module version" '<!ENTITY moduleVersion "1.0.0">' "$plg"
assert_grep "plg points at the release URL" 'releases/download/v0.0.0-dev/gpu-unlock-0000.00.00.0_dev-noarch-1.txz' "$plg"
sed 's/<SHA256>/<MD5>/; s/<\/SHA256>/<\/MD5>/' "$plg" >"$tmp/bad.plg"
assert_rc "lint-plg rejects MD5" 1 "$REPO/scripts/lint-plg" "$tmp/bad.plg"
sed 's|"https://github.com/tabilzad/gpu-unlock-unraid/releases/download/|"https://example.com/|' "$plg" >"$tmp/bad2.plg"
assert_rc "lint-plg rejects a foreign URL" 1 "$REPO/scripts/lint-plg" "$tmp/bad2.plg"

rm -rf "$tmp"
finish
