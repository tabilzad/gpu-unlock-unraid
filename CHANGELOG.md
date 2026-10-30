# Changelog

All notable changes to the GPU Unlock plugin for Unraid. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- The nightly Modules workflow failed every night since 2026-10-28, as soon
  as every kernel in scope already had its module: an empty list fed to
  `grep -v` under `pipefail` ended the discover step with exit 1. Blank
  lines are now dropped with `sed`, and an empty list prints "nothing to
  build".
- A supported card that another driver held at boot (vfio-pci for a VM,
  which `all` does not avoid) is reported as "skipped (bound to vfio-pci at
  boot)" instead of "failed (unlock failed (-16))", and no longer triggers
  a warning notification at every boot.
- Per-card verdicts and the kernel log on the page no longer turn into
  "pending (no result in the kernel log)" after enough uptime for the
  kernel's ring buffer to forget the boot: `report` keeps a copy of the
  lines in `/run/gpu-unlock/kernel.log` at boot.

### Changed

- gpu_unlock 2.0.0 (Zagitta/gpu-unlock at 0532473, "Release 2.0") replaces
  1.0.0. The module now also accepts Turing (RTX 20) and Ada Lovelace
  (RTX 40) cards, which upstream marks experimental: 87 device ids in all.
  Two GA106 laptop ids that 1.0.0 accepted (10de:2520, 10de:2560) are not in
  2.0.0's table. Every kernel's module is rebuilt; the kernel releases gain
  `gpu_unlock-2.0.0-<kernel>.ko` next to the 1.0.0 build that installed
  0.2.x plugins keep using.
- The firmware set grows from five files to sixteen, all taken from NVIDIA's
  driver installer and kernel module source (the CachyOS package is no
  longer an input; the `v67` payload now lives in the module). The
  generator checks both downloads against a SHA-256 pinned in
  `versions.env`, since upstream's fetcher stopped checking them, and
  refuses an output set that lacks any file the module loads.
- Firmware generated for 1.0.0 is reported as "incomplete" by `check`,
  `status` and the page, with a notification asking to generate it again.
  The boot hook still stages it, so Ampere cards stay unlocked meanwhile;
  Turing and Ada cards need the new set.
- `status` and the page explain that no hook record and gpu_unlock not
  loaded are expected until the first boot after the install, and what it
  means if it stays so after a reboot (reported in #1).
- The "no module for kernel" notification names a failed download as the
  other possible cause, and how to retry.
- README: the status reflects the real-hardware confirmation in #1 (RTX 3090
  and RTX 3060 on Unraid 7.3.4), and the Nvidia-Driver plugin is listed as
  required, since the hook only runs when `nvidia` loads.
- The two remaining GitHub Actions in CI are pinned by commit like the rest.

## [0.2.0] - 2026-10-26

Adopts what the other Unraid ports of gpu-unlock do better
(EEEEgoose/unlockGPU4Unraid, nonkronk/unraid-3090-unlock) without giving up
the modprobe install rule, which keeps the NVIDIA driver's boot timing and
never leaves the server without a driver.

### Added

- Card selection on the settings page: tick the supported cards (or "all")
  and save. The hook reads `/boot/config/plugins/gpu-unlock/targets`; the
  kernel command line is no longer required, but `gpu_unlock.targets=` on
  the boot entry still overrides the page. `gpu-unlock-ctl targets` does the
  same from a terminal and refuses addresses that are not supported cards.
- Per-card verdicts parsed from the kernel log (unlocked, failed with the
  module's reason, skipped, pending) on the page, in `status --json` and in
  `status`, with a "power off required" banner when the module reported
  WPR2 already up or firmware that did not stop.
- `gpu-unlock-ctl report`, run by post-install at every boot: one Unraid
  notification per boot with the outcome (alert for a required power off,
  warning for failures, normal for success).
- Module builds check every imported symbol against the kernel's
  `System.map` (nothing else does with CONFIG_MODVERSIONS off).

### Changed

- Documentation: a plain reboot usually resets a card the driver had
  initialised (observed by unlockGPU4Unraid on two RTX 3080); a full power
  off is the sure way, and the page now says so when a card needs it.

## [0.1.1] - 2026-10-26

### Fixed

- Module downloads give up after 10 s without a connection and 120 s in
  total, so a boot without network no longer waits minutes in the plugin
  install step.
- A failed download during `check` no longer aborts the rest of the check.

## [0.1.0] - 2026-10-26

First release. Not yet verified on real hardware by the author; the boot
mechanism is the one reported working on Unraid 7.3.4 with an RTX 3090 in
Zagitta/gpu-unlock#55.

### Added

- Boot hook: a `/boot/config/modprobe.d` install rule loads `gpu_unlock.ko`
  right before the NVIDIA driver, with the targets from
  `gpu_unlock.targets=` on the kernel command line. Skips in Safe Mode, when
  disabled, or when the module or firmware is missing; never fails the nvidia
  load; records what it did in `/run/gpu-unlock/hook.status`.
- `gpu-unlock-ctl`: status (text and JSON), fetch, check, firmware generate
  and import, enable, disable, hook-install, pending-kernel, uninstall.
- Per-kernel modules built by GitHub Actions against ich777's prepared Unraid
  kernel trees and published as releases named after the kernel; a daily job
  builds new kernels as ich777 publishes them.
- Module fetch for the running kernel and for a staged Unraid update (read
  from `/boot/bzimage`) at every boot and daily by cron, with Unraid
  notifications.
- Firmware generated on the server with Docker from NVIDIA's pinned,
  checksummed downloads, using upstream's generators; nothing NVIDIA is
  redistributed.
- Settings page (Settings, User Utilities, GPU Unlock) with status, the
  detected cards, buttons for every action and the opt-in instructions.
