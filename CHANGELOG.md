# Changelog

All notable changes to the GPU Unlock plugin for Unraid. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
