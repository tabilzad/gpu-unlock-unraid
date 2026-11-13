#!/bin/bash
# The settings page and its endpoints: GpuUnlock.page, include/view.php and
# include/exec.php run by PHP against a fake root, with the real control tool
# behind them, through every state the page distinguishes.
set -uo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! command -v php >/dev/null 2>&1; then
  echo "page: php is not installed, the page tests need it" >&2
  exit 1
fi

echo "page: presentation helpers and the view model"
assert_rc "ui-test.php" 0 php "$REPO/tests/helpers/ui-test.php"

setup_root
FLASH="$ROOT/boot/config/plugins/gpu-unlock"
RUN="$ROOT/run/gpu-unlock"
export GU_KVER=6.18.58-Unraid
html="$ROOT/page.html"
body="$ROOT/endpoint.out"
code="$ROOT/endpoint.err"

# render [THEME]: the page as the WebGUI would serve it, into $html.
render() {
  php "$REPO/tests/helpers/render-page.php" "${1:-black}" >"$html" 2>"$ROOT/page.err"
}
# endpoint exec|view METHOD [key=value ...]: body into $body, "http CODE" into $code.
endpoint() {
  php "$REPO/tests/helpers/run-endpoint.php" "$@" >"$body" 2>"$code"
}
# has / lacks MSG TEXT: a fixed string in the rendered page.
has() {
  if grep -qF -- "$2" "$html"; then pass "$1"; else fail "$1 (no '$2' in the page)"; fi
}
lacks() {
  if grep -qF -- "$2" "$html"; then fail "$1 (found '$2' in the page)"; else pass "$1"; fi
}

mkdir -p "$ROOT/usr/share/hwdata" "$RUN"
printf '10de  NVIDIA Corporation\n\t1e04  TU102 [GeForce RTX 2080 Ti]\n\t2204  GA102 [GeForce RTX 3090]\n\t\t10de 147d  a subsystem line\n10df  Emulex Corporation\n\t2204  not this one\n' >"$ROOT/usr/share/hwdata/pci.ids"
fake_card 0000:01:00.0 0x2204 nvidia
fake_card 0000:02:00.0 0x1234
fake_card 0000:03:00.0 0x1e04 vfio-pci

echo "page: a fresh install"
assert_rc "the page renders" 0 render white-bannered
assert "nothing on stderr" test ! -s "$ROOT/page.err"
has "root element with the theme" '<div id="gu" class="gu" data-theme="white">'
has "stylesheet with a cache token" 'href="/plugins/gpu-unlock/styles/gpu-unlock.css?v='
has "script with a cache token" 'src="/plugins/gpu-unlock/javascript/gpu-unlock.js?v='
has "headline names the first thing in the way" 'Not ready yet: no module for kernel 6.18.58-Unraid is on the flash drive.'
has "the view carries no targets" 'data-targets="" data-locked="0"'
has "the module step is the one to act on" '<li class="gu-step gu-step-current" data-tone="warn" data-step="module">'
has "with its button" 'data-action="fetch"><svg'
has "the firmware step offers the generation" '<span>Generate firmware</span>'
has "the boot rule step offers the install" '<span>Install boot rule</span>'
has "card name from the PCI id database" '<div class="gu-card-name">GeForce RTX 3090</div>'
has "address and device id" '<span class="gu-mono">0000:01:00.0</span><span class="gu-mono">10de:2204</span>'
has "an unsupported card is listed without a box" '<span class="gu-badge" data-tone="neutral" title="gpu_unlock'
has "Turing is marked experimental" 'data-tone="warn" title="Upstream marks Turing'
has "a card held by vfio-pci says so" '>vfio-pci</span>'
assert "two boxes for two supported cards" test "$(grep -c 'class="gu-pick"' "$html")" = 2
lacks "nothing is ticked" '" checked'
has "the Save button waits for a change" 'id="gu-save" data-action="save-targets" disabled>'
has "no NVIDIA driver: the notice says what triggers the unlock" 'The NVIDIA driver is not loaded.'
has "this boot: not run" '<div class="gu-card-value">Not run</div>'
has "cells are labelled for the stacked layout" '<td data-label="This boot">'
lacks "no version line without an installed package" 'Plugin unknown'
mkdir -p "$ROOT/sys/module/nvidia"
render
has "default theme is black" 'data-theme="black"'
lacks "with the driver loaded the notice is gone" 'The NVIDIA driver is not loaded.'

echo "page: ready for the next boot"
ctl hook-install >/dev/null
fake_release 6.18.58-Unraid
ctl fetch >/dev/null
fake_firmware "$FLASH/firmware"
ctl targets set 0000:01:00.0 >/dev/null
render
has "headline: ready" 'Ready. The unlock runs the next time the server is powered on.'
has "next boot card" '<div class="gu-card-value">Ready</div>'
has "one of two supported cards chosen" '<div class="gu-card-value">1 of 2</div>'
has "the saved selection is in the view" 'data-targets="0000:01:00.0" data-locked="0"'
has "and ticked" 'value="0000:01:00.0" aria-label="Unlock GeForce RTX 3090 at 0000:01:00.0" checked>'
has "the power cycle is the step to act on" '<li class="gu-step gu-step-current" data-tone="info" data-step="power">'
has "the chosen card waits for the boot" '>at the next boot</span>'
assert "four steps are done" test "$(grep -c '<li class="gu-step" data-tone="ok"' "$html")" = 4
assert_grep "the setup list is open while a step is left" '<details class="gu-section gu-setup" data-key="setup-[0-4]" open>' "$html"
has "and counts what is done" '>4 of 5 done</span>'
lacks "no notice" 'class="gu-notice"'
has "modules on the flash drive" '<span class="gu-mono">6.18.58-Unraid</span>'

echo "page: after a boot that unlocked the card"
printf 'loaded: gpu_unlock for 6.18.58-Unraid, targets=0000:01:00.0 (from the settings page); per-card result in the kernel log\n' >"$RUN/hook.status"
printf '[   36.265856] pci 0000:01:00.0: gpu_unlock: unlocked\n[   36.404776] NVRM: loading NVIDIA UNIX Open Kernel Module for x86_64  580.196.07\n' >"$ROOT/var/log/dmesg"
mkdir -p "$ROOT/sys/module/gpu_unlock" "$ROOT/proc/driver/nvidia/gpus/0000:01:00.0"
printf 'Model: \t\t NVIDIA GeForce RTX 3090\nIRQ:   \t\t 131\nBus Location: \t 0000:01:00.0\n' >"$ROOT/proc/driver/nvidia/gpus/0000:01:00.0/information"
render
has "headline: unlocked" '<h2 class="gu-hero-title">1 card unlocked this boot.</h2>'
has "the header takes the tone" '<div class="gu-hero" data-tone="ok">'
has "card name from the NVIDIA driver" '<div class="gu-card-name">NVIDIA GeForce RTX 3090</div>'
has "per-card result" '<span class="gu-badge" data-tone="ok">unlocked</span>'
has "a card that was not chosen says so" '>not chosen</span>'
has "the verdict line stands out in the kernel log" '<span class="gu-log-ok">[   36.265856] pci 0000:01:00.0: gpu_unlock: unlocked</span>'
has "every step is done" 'Done: 1 card was unlocked this boot'
lacks "no step to act on" 'gu-step-current'
has "the setup list folds away" '<details class="gu-section gu-setup" data-key="setup-5">'
has "with everything done" '<span class="gu-badge" data-tone="ok">5 of 5 done</span>'

echo "page: a card that needs a power off, and one that failed"
cat >"$ROOT/var/log/dmesg" <<'EOF'
[   41.199010] pci 0000:01:00.0: card already initialised since power on (WPR2 enabled); power off first
[   41.199020] pci 0000:01:00.0: gpu_unlock: unlock failed (-16)
EOF
render
has "headline: power off" '<h2 class="gu-hero-title">Power off required.'
has "the headline says what to do" 'Shut the server down, wait a few seconds and power it on'
has "the header takes the tone" '<div class="gu-hero" data-tone="bad">'
has "the card carries the badge" '<span class="gu-badge" data-tone="bad">power off required</span>'
has "the failing line stands out" '<span class="gu-log-bad">[   41.199020] pci 0000:01:00.0: gpu_unlock: unlock failed (-16)</span>'
printf '[   41.101010] pci 0000:01:00.0: gpu_unlock: firmware load failed (-2)\n' >"$ROOT/var/log/dmesg"
render
has "headline: failed" '1 card failed to unlock this boot.'
has "the reason is next to the card" '<span class="gu-reason">firmware load failed (-2)</span>'
printf '[   36.265856] pci 0000:01:00.0: gpu_unlock: unlocked\n' >"$ROOT/var/log/dmesg"

echo "page: a staged Unraid update"
fake_bzimage 6.18.70-Unraid
render
has "the notice asks to fetch before the reboot" 'the next boot runs kernel 6.18.70-Unraid'
has "with the button" 'data-action="fetch-pending"><svg'
has "next boot is not ready" 'The next boot is not ready: no module for kernel 6.18.70-Unraid is on the flash drive.'
fake_release 6.18.70-Unraid
endpoint exec POST action=fetch-pending
assert_grep "fetch-pending through the endpoint" '"ok":true' "$body"
render
has "the staged kernel's module is there" 'is on the flash drive for 6.18.70-Unraid, the staged Unraid update the next boot runs, and for 6.18.58-Unraid.'
lacks "the notice is gone" 'data-action="fetch-pending"'
rm -f "$ROOT/boot/bzimage"

echo "page: targets on the kernel command line"
set_cmdline gpu_unlock.targets=all
render
has "the view is locked" 'data-targets="all" data-locked="1"'
has "an info notice explains it" 'gpu_unlock.targets=all on the kernel command line decides the cards'
has "boxes are ticked and disabled" 'at 0000:01:00.0" checked disabled>'
lacks "no Save button" 'id="gu-save"'
set_cmdline

echo "page: firmware generation, running and failed"
rm -rf "$FLASH/firmware"
printf 'building gpu-unlock/firmware-gen:2.0.0 from /usr/local/emhttp/plugins/gpu-unlock/docker\ngenerating firmware 610.43.03 with gpu-unlock/firmware-gen:2.0.0 (downloads about 370 MB)\nfirmware-gen: gpu-unlock 2.0.0, NVIDIA 610.43.03, 16 firmware files\n' >"$RUN/firmware.log"
echo $$ >"$RUN/firmware.pid"
render
has "the view says a job runs" 'data-job="1" data-job-rc=""'
has "the headline follows the job" 'The next boot is not ready: the firmware is being generated.'
has "the firmware step is running" '<li class="gu-step gu-step-current" data-tone="info" data-step="firmware">'
has "the image is built" '<li class="gu-phase" data-state="done">Build the generator image</li>'
has "the download is the active phase" '<li class="gu-phase" data-state="active">Download NVIDIA'
has "the log is shown" 'firmware-gen: gpu-unlock 2.0.0, NVIDIA 610.43.03, 16 firmware files</pre>'
lacks "no second generation is offered while one runs" 'data-action="firmware"'
echo 999999999 >"$RUN/firmware.pid"
echo 1 >"$RUN/firmware.rc"
render
has "the job is over" 'data-job="0" data-job-rc="1"'
has "the phase it stopped in is marked" '<li class="gu-phase" data-state="failed">Download NVIDIA'
has "the step says it failed and offers another run" 'The last generation failed; the log below says why.'
has "the generation is offered again" 'data-action="firmware"'
rm -f "$RUN/firmware.pid" "$RUN/firmware.rc" "$RUN/firmware.log"

echo "page: firmware generated for an earlier gpu_unlock"
fake_firmware "$FLASH/firmware" old
render
assert_grep "a notice counts the missing files" "lacks [0-9]* files that $MV loads" "$html"
has "the next boot is ready with a caveat" 'firmware incomplete: some cards may fail'
has "the step offers another generation" '<span>Generate firmware again</span>'
fake_firmware "$FLASH/firmware"

echo "page: everything the control tool reports is escaped"
printf 'loaded: <img src=x onerror=alert(1)> "quoted"\n' >"$RUN/hook.status"
printf '[   36.2] pci 0000:01:00.0: gpu_unlock: unlocked\n[   36.3] gpu_unlock: <script>alert("log")</script> \033[31mred\n' >"$ROOT/var/log/dmesg"
printf '10de  NVIDIA Corporation\n\t2204  GA102 [<b>"bold"</b>]\n' >"$ROOT/usr/share/hwdata/pci.ids"
rm -rf "$ROOT/proc/driver/nvidia"
ln -sfn '../../../bus/pci/drivers/<i>drv' "$ROOT/sys/bus/pci/devices/0000:03:00.0/driver"
printf 'install nvidia /bin/true\n' >"$ROOT/boot/config/modprobe.d/o\"x<u>.conf"
printf 'building\n</pre><script>alert("fw")</script>\n' >"$RUN/firmware.log"
echo $$ >"$RUN/firmware.pid"
assert_rc "the page renders" 0 render
for raw in '<img src=x' '<script>alert' '<b>"bold"' '<i>drv' '<u>.conf'; do
  lacks "raw $raw" "$raw"
done
has "hook status escaped" 'loaded: &lt;img src=x onerror=alert(1)&gt; &quot;quoted&quot;'
has "kernel log escaped, control characters dropped" 'gpu_unlock: &lt;script&gt;alert(&quot;log&quot;)&lt;/script&gt; [31mred'
has "card name escaped" '<div class="gu-card-name">&lt;b&gt;&quot;bold&quot;&lt;/b&gt;</div>'
has "driver name escaped" '&lt;i&gt;drv'
has "conflicting file name escaped" 'o&quot;x&lt;u&gt;.conf'
has "firmware log escaped" '&lt;/pre&gt;&lt;script&gt;alert(&quot;fw&quot;)&lt;/script&gt;'
assert "the document still has one root view" test "$(grep -c 'class="gu-view"' "$html")" = 1
rm -f "$ROOT/boot/config/modprobe.d/o\"x<u>.conf" "$RUN/firmware.pid" "$RUN/firmware.log"
rm -f "$ROOT/sys/bus/pci/devices/0000:03:00.0/driver"
printf '[   36.265856] pci 0000:01:00.0: gpu_unlock: unlocked\n' >"$ROOT/var/log/dmesg"
printf 'loaded: gpu_unlock for 6.18.58-Unraid\n' >"$RUN/hook.status"

echo "endpoint: view"
endpoint view GET
assert_grep "view answers 200" '^http 200$' "$code"
assert_grep "view is the page's content" '<div class="gu-view" data-job="0"' "$body"
assert_not_grep "view carries no stylesheet or script" '<link\|<script' "$body"
render
# The page is the root element around the same content; the free space is
# left out, it can change between two calls.
content() { sed '/Free space/{n;d}' "$1" | sha256sum; }
sed -n '/^<div id="gu"/,/^<script src=/p' "$html" | sed '1d;$d' | sed '$d' >"$ROOT/inner.html"
assert "view and the page render the same content" test "$(content "$ROOT/inner.html")" = "$(content "$body")"

echo "endpoint: exec"
endpoint exec GET
assert_grep "GET is refused" '^http 405$' "$code"
endpoint exec POST action=reboot
assert_grep "an unknown action is refused" '^http 400$' "$code"
assert_grep "with an error" '"error":"unknown action"' "$body"
endpoint exec POST 'action=targets' 'targets=all;reboot'
assert_grep "malformed targets are refused" '^http 400$' "$code"
assert "and the saved selection is untouched" test "$(cat "$FLASH/targets")" = 0000:01:00.0
endpoint exec POST action=targets targets=0000:02:00.0
assert_grep "an unsupported card is refused by the control tool" '^http 400$' "$code"
assert_grep "with its reason" "is not a card gpu_unlock $MV supports" "$body"
endpoint exec POST action=targets targets=all
assert_grep "targets=all is saved" '^http 200$' "$code"
assert "the file says all" test "$(cat "$FLASH/targets")" = all
endpoint exec POST action=targets-clear
assert "targets-clear removes the file" test ! -e "$FLASH/targets"
endpoint exec POST action=targets targets=0000:01:00.0
endpoint exec POST action=disable
assert "disable writes the marker" test -e "$FLASH/disabled"
render
has "the page offers to enable it again" '<span>Enable</span>'
has "next boot: switched off" '<div class="gu-card-value">Switched off</div>'
endpoint exec POST action=enable
assert "enable removes it" test ! -e "$FLASH/disabled"
endpoint exec POST action=diagnostics
assert_grep "diagnostics is the status text" '=== gpu-unlock plugin' "$body"
assert_grep "with the card and its name" 'chip=GA102' "$body"
endpoint exec POST action=check
assert_grep "check with everything in place" '^http 200$' "$code"

echo "endpoint: the background firmware job keeps its exit status"
# A docker that is not running, whatever the machine running the tests has.
mkdir -p "$ROOT/bin"
printf '#!/bin/sh\nexit 1\n' >"$ROOT/bin/docker"
chmod +x "$ROOT/bin/docker"
PATH="$ROOT/bin:$PATH" endpoint exec POST action=firmware
assert_grep "the job starts" 'firmware generation started in the background' "$body"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -s "$RUN/firmware.rc" ] && break
  sleep 0.5
done
assert "it fails without a Docker service" test "$(cat "$RUN/firmware.rc" 2>/dev/null)" = 1
assert_grep "the log has the reason" 'the Docker service is not running' "$RUN/firmware.log"
render
has "the page reports the failed job" 'data-job="0" data-job-rc="1"'
has "and that the firmware on the flash drive is untouched" 'Generating it again failed and changed nothing'

echo "page: a control tool that does not answer"
printf '#!/bin/sh\nexit 3\n' >"$ROOT/usr/local/sbin/gpu-unlock-ctl"
assert_rc "the page still renders" 0 render
has "it says so" 'gpu-unlock-ctl did not answer'
has "and offers to try again" 'data-refresh="1"'
lacks "no setup steps" 'gu-steps'

rm -rf "$ROOT"
finish
