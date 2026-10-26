#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# gpu-unlock boot hook for Unraid. modprobe runs it right before it loads
# nvidia, through /boot/config/modprobe.d/gpu-unlock.conf:
#
#   install nvidia /bin/sh /boot/config/plugins/gpu-unlock/pre-nvidia.sh; \
#       /sbin/modprobe --ignore-install nvidia $CMDLINE_OPTS
#
# It loads the gpu_unlock.ko built for the running kernel, with the cards
# chosen on the settings page (the targets file next to this script) or given
# as gpu_unlock.targets= on the kernel command line, and never fails the
# nvidia load: every problem is logged (kernel log and /run/gpu-unlock/hook.status)
# and nvidia loads as usual. Nothing happens without chosen cards, in Safe
# Mode, or while /boot/config/plugins/gpu-unlock/disabled exists.
#
# Why here: Unraid installs the cached NVIDIA plugin package in rc.modules and
# udev coldplug loads nvidia before /boot/extra, plugins or the go script run,
# so a modprobe install rule is the only place that is early enough (approach
# proven on Unraid 7.3.4 in https://github.com/Zagitta/gpu-unlock/issues/55).
#
# The plugin copies this file to the flash drive; the copy there is what runs.
# GPU_UNLOCK_ROOT and GPU_UNLOCK_KVER exist for the test suite only.

R=${GPU_UNLOCK_ROOT:-}
BASE=$R/boot/config/plugins/gpu-unlock
RUN=$R/run/gpu-unlock
FWROOT=$R/lib/firmware

log() {
    printf '<6>gpu-unlock: %s\n' "$*" > /dev/kmsg 2>/dev/null || echo "gpu-unlock: $*" >&2
}
# status WORD: REASON   recorded for the settings page, then logged.
status() {
    mkdir -p "$RUN" 2>/dev/null && printf '%s\n' "$*" > "$RUN/hook.status" 2>/dev/null
    log "$*"
}

if [ "${1:-}" != --locked ]; then
    # udev fires several modprobe nvidia calls at once; do the work once.
    # The file-name form of flock is the one that works at early boot.
    mkdir -p "$RUN" 2>/dev/null
    ERR=$RUN/hook.err
    /usr/bin/flock -x "$RUN/hook.lock" /bin/sh "$0" --locked 2>"$ERR"
    rc=$?
    if [ -s "$ERR" ]; then
        while IFS= read -r line; do log "$line"; done < "$ERR"
    fi
    [ "$rc" -eq 0 ] || log "hook exited $rc; nvidia loads as usual"
    exit 0
fi

[ ! -d "$R/sys/module/gpu_unlock" ] || exit 0
if [ -e "$BASE/disabled" ]; then
    status 'skipped: disabled (gpu-unlock-ctl enable to undo)'; exit 0
fi
if [ -f "$R/boot/unraidsafemode" ] || grep -qw unraidsafemode "$R/proc/cmdline" 2>/dev/null; then
    status 'skipped: Safe Mode'; exit 0
fi

# The cards: gpu_unlock.targets= on the kernel command line wins; otherwise
# the targets file the settings page (gpu-unlock-ctl targets) writes.
TARGETS=
SOURCE='the kernel command line'
# shellcheck disable=SC2013 # the command line is one line of words
for arg in $(cat "$R/proc/cmdline" 2>/dev/null); do
    case "$arg" in
        gpu_unlock.targets=*) TARGETS=${arg#gpu_unlock.targets=} ;;
    esac
done
if [ -z "$TARGETS" ] && [ -r "$BASE/targets" ]; then
    TARGETS=$(head -n 1 "$BASE/targets" 2>/dev/null | tr -d '\r[:space:]')
    SOURCE='the settings page'
    if ! printf '%s' "$TARGETS" | grep -Eq '^(all|[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7](,[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7])*)$'; then
        status "skipped: malformed targets file $BASE/targets (gpu-unlock-ctl targets set ...)"; exit 0
    fi
fi
if [ -z "$TARGETS" ]; then
    status 'skipped: no cards chosen (Settings, GPU Unlock, or gpu_unlock.targets= on the kernel command line)'; exit 0
fi

KVER=${GPU_UNLOCK_KVER:-$(uname -r)}
KDIR=$BASE/modules/$KVER
if [ ! -r "$KDIR/gpu_unlock.ko" ]; then
    status "skipped: no module for kernel $KVER on the flash drive (gpu-unlock-ctl fetch)"; exit 0
fi
if ! (cd "$KDIR" && sha256sum -c SHA256SUMS > /dev/null 2>&1); then
    status "skipped: checksum mismatch in $KDIR (gpu-unlock-ctl fetch --force)"; exit 0
fi

# /lib/firmware is RAM-backed on Unraid; request_firmware() looks there.
if [ ! -d "$FWROOT/gpu-unlock" ]; then
    if [ ! -f "$BASE/firmware/SHA256SUMS" ]; then
        status 'skipped: no firmware on the flash drive (gpu-unlock-ctl firmware)'; exit 0
    fi
    if ! (cd "$BASE/firmware" && sha256sum -c SHA256SUMS > /dev/null 2>&1); then
        status 'skipped: firmware checksum mismatch (gpu-unlock-ctl firmware)'; exit 0
    fi
    if ! mkdir -p "$FWROOT" || ! cp -R "$BASE/firmware/gpu-unlock" "$FWROOT/"; then
        status 'skipped: could not copy the firmware into /lib/firmware'; exit 0
    fi
fi

log "loading gpu_unlock for $KVER with targets=$TARGETS (from $SOURCE) before nvidia"
if /sbin/insmod "$KDIR/gpu_unlock.ko" "targets=$TARGETS"; then
    status "loaded: gpu_unlock for $KVER, targets=$TARGETS (from $SOURCE); per-card result in the kernel log"
else
    status "failed: insmod gpu_unlock.ko with targets=$TARGETS (from $SOURCE); nvidia loads as usual"
fi
exit 0
