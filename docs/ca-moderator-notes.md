# Notes for the Community Applications moderators

Factual notes for the review of the **GPU Unlock** plugin submission (`gpu-unlock`).
Everything here can be checked in the repository:
<https://github.com/tabilzad/gpu-unlock-unraid>.

## 1. What it does, and why a plugin

It runs the `gpu_unlock` kernel module from
[Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock) (GPL-2.0) on GeForce RTX 30
series cards before the NVIDIA driver binds them, which unlocks their full FP16/BF16
tensor rate. The NVIDIA driver is not patched or modified. RTX 40 series support is
experimental upstream. RTX 20 series cards are refused by the plugin while the pinned
gpu_unlock (2.0.0) is known to fail on them (`KNOWN_BAD_CHIPS` in `versions.env`).

The module has to run before `nvidia` initialises the card, which on Unraid happens
during early boot, before the plugin phase, the `go` script or Docker. A container or a
plugin step comes too late. The one place early enough is a modprobe rule, which Unraid
copies from the flash drive before udev loads the driver (section 3).

## 2. What is downloaded, from where, and how it is checked

| What | From | Check |
| --- | --- | --- |
| The plugin package (about 40 KB) | this repository's release, the plg's only `<FILE><URL>` | `<SHA256>` in the plg; cached on the flash drive, so a boot with a valid cache downloads nothing |
| `gpu_unlock.ko` for the exact running kernel and for a staged Unraid update (about 120 KB each) | this repository's releases named after the kernel (for example `6.18.58-Unraid`) | a `.sha256` file from the same release |
| The firmware generator's inputs: NVIDIA's driver installer and kernel-module source for 610.43.03 (about 370 MB) | `download.nvidia.com`, inside a Docker build on the server | SHA-256 values pinned in `versions.env` and passed into the build; any other content is refused |

**The kernel module is a prebuilt binary.** The `Modules` workflow
(`.github/workflows/modules.yml`, `scripts/build-module`) builds it on GitHub Actions
from the upstream commit pinned in `versions.env` (`UPSTREAM_REF`), against
[ich777's prepared Unraid kernel trees](https://github.com/ich777/unraid_kernel/releases).
Each release lists the upstream commit and the tree it was built from, and a
`.manifest.txt` beside the module records the same. The `.sha256` comes from the same
release, so it shows the download is intact, not who built it. The build can be
repeated with `./scripts/build-module --kver <kernel>` (Docker).

**No NVIDIA file is redistributed.** The firmware the module needs is generated on the
user's server by upstream's own generator scripts, in a Docker image built locally from
`python:3.12-alpine` and the pinned upstream commit
(`src/usr/local/emhttp/plugins/gpu-unlock/docker/`). The result (16 files, about 110 MB)
is verified against its `SHA256SUMS` before it replaces anything. NVIDIA's licence
files are kept beside it.

Modules are fetched only when one is missing: at install and at boot (the plugin
phase), from the cron job, and from the settings page. The firmware inputs are
downloaded only when the user generates the firmware. A failed download never fails the
install and never blocks a boot: the plugin reports it (notification, settings page,
`gpu-unlock-ctl status`) and tries again later.

## 3. What it changes outside its own folder

- **`/boot/config/modprobe.d/gpu-unlock.conf`**, one line:

  ```
  install nvidia /bin/sh /boot/config/plugins/gpu-unlock/pre-nvidia.sh; /sbin/modprobe --ignore-install nvidia $CMDLINE_OPTS
  ```

  The `;` means `nvidia` is loaded whatever the hook does, also if the hook is missing.
  The hook does nothing in Safe Mode, while `/boot/config/plugins/gpu-unlock/disabled`
  exists (the page's *Switch off*), or when no card is chosen. When another file in
  `modprobe.d` already carries an `install nvidia` rule, the plugin does not write its
  own and warns instead.
- **A cron file** (`/boot/config/plugins/gpu-unlock/gpu-unlock.cron`, installed with
  `update_cron`): every minute it compares the kernel version of `/boot/bzimage` with
  the last one seen (a staged Unraid update replaces it), and once a day it runs
  `gpu-unlock-ctl check`.
- **In RAM only**: `/usr/local/sbin/gpu-unlock-ctl`, the WebGUI page, `/run/gpu-unlock`,
  and the firmware copied into `/lib/firmware/gpu-unlock` by the hook at boot.
- **Docker**: the generator image `gpu-unlock/firmware-gen:<version>` stays in Docker's
  image store after the firmware is generated, so a second generation needs no rebuild.
  Uninstalling the plugin does not remove it; the Docker page or `docker rmi` does.

Nothing touches the `go` file, `/boot/extra`, `/boot/syslinux` or the NVIDIA driver
plugin's files. The kernel command line option `gpu_unlock.targets=` is supported but
only ever added by the user.

## 4. Failure behaviour

- The worst normal outcome is a boot without the unlock: the driver loads as usual.
- One known exception: when an unlock stops half-way, gpu_unlock keeps the card's
  resources until power off, and the NVIDIA driver cannot use that card for the rest of
  that boot (issue [#3](https://github.com/tabilzad/gpu-unlock-unraid/issues/3), with
  Turing). Since 0.4.1 the hook records this and leaves that card alone at the next
  boot, so the driver works again after one reboot; the page says so and offers
  *Try again*. Chips the pinned module is known to fail on are never tried.
- Every install step except the package install exits 0, so the plg never lands in
  `plugins-error` because of the network or a missing module.

## 5. Flash footprint

Under `/boot/config/plugins/gpu-unlock/`: the package (about 40 KB), the modules for the
running and the staged kernel (about 120 KB each), the firmware (about 110 MB, written
once per gpu_unlock version), the hook copy, the chosen cards (`targets`), and markers.
Plus the one-line rule in `/boot/config/modprobe.d/`. At every boot the plugin rewrites
two small text files (the cron file and the list of chips the module is known to fail
on); the hook copy and the rule are written only when they differ.

## 6. Removal

Uninstalling removes the modprobe rule, the hook copy, the modules, the cron job, the
package and everything in RAM. It keeps the generated firmware and the settings (they
took a 370 MB download to make), and says how to delete them:
`rm -rf /boot/config/plugins/gpu-unlock`.

## 7. Upstream's own Unraid plugin uses the same name

Zagitta/gpu-unlock also ships an Unraid plugin (`packaging/unraid/gpu-unlock.plg`,
Unraid 7.3 and newer, not in Community Applications). It has the same plugin name, so
the same `/boot/config/plugins/gpu-unlock.plg` and folder; only one of the two can be
installed. The README explains the difference: upstream's plugin writes its
`softdep nvidia pre: gpu_unlock` rule from the plugin phase, which on Unraid 7.3 runs
after the driver has loaded (upstream issue
[#298](https://github.com/Zagitta/gpu-unlock/issues/298)).

Switching from upstream's plugin to this one leaves nothing that can stop the driver.
This plugin ignores the `TARGETS` setting in upstream's `gpu-unlock.cfg` (the cards
come from the settings page). It does not accept upstream's firmware folder (a different
layout): it reports the firmware as missing or incomplete, the boot skips the unlock
until the user generates it, and the generation replaces the folder. Upstream's cached
packages stay in the folder until removed by hand.

## 8. Tests

`./scripts/dev-env --root make check` runs shellcheck, shfmt, `php -l`, an escaping
lint for the page, the plg lint, this wrapper's lint (`make lint-ca`) and the test
suite. The suite runs the real hook, control tool, install and remove scripts against a
fake root, installs the package with Slackware's pkgtools, and renders the settings page
in every state with hostile values. Confirmed on hardware: Unraid 7.3.4 with an RTX 3090
and an RTX 3060 ([#1](https://github.com/tabilzad/gpu-unlock-unraid/issues/1)).
