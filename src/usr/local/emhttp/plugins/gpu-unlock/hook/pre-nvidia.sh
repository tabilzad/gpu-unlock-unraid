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

MV=$(sed -n 's/^module_version=//p' "$KDIR/manifest.txt" 2>/dev/null | head -n 1)

# nvidia_cards: ADDRESS DEVICE of every NVIDIA display controller present.
nvidia_cards() {
    for d in "$R"/sys/bus/pci/devices/*; do
        [ "$(cat "$d/vendor" 2>/dev/null)" = 0x10de ] || continue
        case "$(cat "$d/class" 2>/dev/null)" in 0x0300* | 0x0302*) ;; *) continue ;; esac
        printf '%s %s\n' "$(basename "$d")" "$(cat "$d/device" 2>/dev/null)"
    done
}
# target_list: the chosen cards as addresses, "all" resolved to the cards present.
target_list() {
    if [ "$TARGETS" = all ]; then nvidia_cards | cut -d' ' -f1; else printf '%s\n' "$TARGETS" | tr ',' '\n'; fi
}
# klog: this boot's kernel log (the test suite provides a file).
klog() {
    if [ -n "$R" ]; then cat "$R/var/log/dmesg" 2>/dev/null; else dmesg 2>/dev/null; fi
}

# Cards this gpu_unlock leaves alone: those held back after an unlock that
# kept the card (markers in held/, written below), and the chips it is known
# to fail on (known-bad, written by gpu-unlock-ctl hook-install). Both are
# keyed to the module version, so a new gpu_unlock gets a fresh try.
HELD=
for f in "$BASE"/held/*; do
    [ -f "$f" ] || continue
    if [ "$(sed -n 's/^module_version=//p' "$f" | head -n 1)" = "$MV" ]; then
        HELD="$HELD $(basename "$f")"
    else
        rm -f "$f"
    fi
done
BAD_IDS=
if [ -r "$BASE/known-bad" ] && [ "$(sed -n 's/^module_version=//p' "$BASE/known-bad" | head -n 1)" = "$MV" ]; then
    BAD_IDS=$(sed -n 's/^ids=//p' "$BASE/known-bad" | head -n 1)
fi
if [ -n "$HELD$BAD_IDS" ]; then
    KEEP=
    LEFT=
    for addr in $(target_list); do
        case " $HELD " in
            *" $addr "*)
                log "holding back $addr: $(sed -n 's/^reason=//p' "$BASE/held/$addr" | head -n 1) (Settings, GPU Unlock: Try again)"
                LEFT="$LEFT $addr"
                continue
                ;;
        esac
        id=$(nvidia_cards | awk -v a="$addr" '$1 == a { sub(/^0x/, "", $2); print $2 }')
        if [ -n "$id" ] && [ -n "$BAD_IDS" ]; then
            case " $BAD_IDS " in
                *" $id "*)
                    log "leaving $addr alone: gpu_unlock $MV is known to fail on this chip and would block the NVIDIA driver (gpu-unlock-ctl status)"
                    LEFT="$LEFT $addr"
                    continue
                    ;;
            esac
        fi
        KEEP="$KEEP,$addr"
    done
    if [ -z "$KEEP" ]; then
        status "skipped: every chosen card is held back or known to fail with gpu_unlock $MV:$LEFT (Settings, GPU Unlock)"; exit 0
    fi
    if [ "$TARGETS" != all ] || [ -n "$LEFT" ]; then
        TARGETS=${KEEP#,}
    fi
    [ -z "$LEFT" ] || SOURCE="$SOURCE; left alone:$LEFT"
fi

log "loading gpu_unlock for $KVER with targets=$TARGETS (from $SOURCE) before nvidia"
# GPU_UNLOCK_INSMOD: test suite only.
if "${GPU_UNLOCK_INSMOD:-/sbin/insmod}" "$KDIR/gpu_unlock.ko" "targets=$TARGETS"; then
    # A card whose unlock failed half-way is kept by the module ("handover
    # refused", "firmware did not stop"), and the NVIDIA driver cannot load it
    # this boot. Hold it back from the next boot so the driver works again;
    # the page offers a retry, and a new gpu_unlock drops the marker itself.
    KEPT=
    for addr in $(target_list); do
        mine=$(klog | grep -F "pci $addr: ")
        if printf '%s\n' "$mine" | grep -q -E 'retained until power off|firmware did not stop'; then
            err=$(printf '%s\n' "$mine" | grep -o 'gpu_unlock: unlock failed ([-0-9]*)' | head -n 1)
            mkdir -p "$BASE/held" 2>/dev/null
            printf 'module_version=%s\nkernel=%s\nreason=%s\n' "$MV" "$KVER" \
                "${err#gpu_unlock: }; the module kept the card and the NVIDIA driver could not load it" > "$BASE/held/$addr" 2>/dev/null
            KEPT="$KEPT $addr"
        fi
    done
    if [ -n "$KEPT" ]; then
        status "loaded: gpu_unlock for $KVER, targets=$TARGETS (from $SOURCE); per-card result in the kernel log; the unlock kept$KEPT, held back from the next boot so the NVIDIA driver loads again"
    else
        status "loaded: gpu_unlock for $KVER, targets=$TARGETS (from $SOURCE); per-card result in the kernel log"
    fi
else
    status "failed: insmod gpu_unlock.ko with targets=$TARGETS (from $SOURCE); nvidia loads as usual"
fi
exit 0
