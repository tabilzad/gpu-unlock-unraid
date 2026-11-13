# GPU Unlock for Unraid

An Unraid plugin that runs [Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock)
at boot: the `gpu_unlock` kernel module unlocks the full FP16/BF16 tensor rate
of GeForce RTX 30 series cards (Ampere: RTX 3090, 3080 Ti, 3080, 3070, 3060 ...)
before the NVIDIA driver binds them, and, experimentally as upstream marks it,
of RTX 20 (Turing) and RTX 40 (Ada Lovelace) cards. The driver itself is not
patched.

Status: **0.3.x**, gpu_unlock 2.0.0. Confirmed on real hardware with gpu_unlock
1.0.0 by a user in [#1](https://github.com/tabilzad/gpu-unlock-unraid/issues/1):
Unraid 7.3.4 (kernel 6.18.58) with an RTX 3090, and a second server with an
RTX 3060 (GA104), both unlocked at the first power cycle. An Unraid update that
was already staged on the flash drive at install time had its module fetched in
advance, and the unlock carried over the reboot. The mechanism is the one
reported working in [gpu-unlock#55](https://github.com/Zagitta/gpu-unlock/issues/55).
2.0.0 is the same unlock for Ampere, with the firmware now taken from NVIDIA's
driver installer; Turing and Ada are new and unconfirmed here. Please report
what happens on yours.

> Not affiliated with NVIDIA, Lime Technology or the gpu-unlock authors.
> Everything here is GPL-2.0-only. No NVIDIA file is redistributed: the
> firmware the module needs is generated on your server from NVIDIA's own
> downloads, exactly as upstream's packages do it.

## How it works

Unraid loads `nvidia` very early: `rc.modules` installs the cached driver
package of the Nvidia-Driver plugin and udev loads the module before
`/boot/extra`, plugins, the `go` script or Docker run. A container or a plugin
script therefore comes too late; `gpu_unlock` refuses a card the driver already
initialised since power-on. The one place that runs early enough is a modprobe
rule, which Unraid restores from the flash drive before udev:

```
install nvidia /bin/sh /boot/config/plugins/gpu-unlock/pre-nvidia.sh; /sbin/modprobe --ignore-install nvidia $CMDLINE_OPTS
```

The hook loads the module built for the running kernel with the targets you
chose, stages the firmware into `/lib/firmware`, logs what it did and lets
nvidia load as usual whatever happens. The plugin's job is to keep the flash
drive ready for that moment:

| piece | where it comes from | where it lives |
| --- | --- | --- |
| `gpu_unlock.ko` for your exact kernel | [releases named after the kernel](https://github.com/tabilzad/gpu-unlock-unraid/releases), built by CI from upstream against [ich777's prepared trees](https://github.com/ich777/unraid_kernel/releases) | `/boot/config/plugins/gpu-unlock/modules/<kernel>/` |
| firmware (16 files, about 110 MB) | generated on your server with Docker by upstream's generators | `/boot/config/plugins/gpu-unlock/firmware/` |
| the hook and the modprobe rule | the plugin package | `/boot/config/plugins/gpu-unlock/pre-nvidia.sh`, `/boot/config/modprobe.d/gpu-unlock.conf` |
| the cards to unlock | the settings page (or the kernel command line) | `/boot/config/plugins/gpu-unlock/targets` |

Two other Unraid ports exist, [EEEEgoose/unlockGPU4Unraid](https://github.com/EEEEgoose/unlockGPU4Unraid)
and [nonkronk/unraid-3090-unlock](https://github.com/nonkronk/unraid-3090-unlock).
Both blacklist the NVIDIA modules (in modprobe.d or on the kernel command
line) and load the driver themselves from the plugin phase minutes later,
which makes them depend on plugin filename order and needs careful fallback
code so a failed plugin does not leave the server without a driver. The
install rule used here runs at the moment udev would have loaded the driver,
so the driver's timing is unchanged and the only failure mode is "no unlock".
The per-card verdicts and the card selection on the page follow their lead.

Since 2.0, Zagitta/gpu-unlock also carries an Unraid plugin of its own
(`packaging/unraid`, Unraid 7.3 and newer). It installs the module as a
package and writes `softdep nvidia pre: gpu_unlock` to `/etc/modprobe.d`
while plugins are installed. On Unraid 7.3 that is after the driver:
`rc.S.cont` runs `rc.modules` (which installs the Nvidia-Driver plugin's
cached package) and starts udev, and `rc.M` only reaches `rc.local`, which
installs the plugins, later. Two reports of "nvidia is already loaded" on
7.3.4, also after a power cycle, are in
[gpu-unlock#298](https://github.com/Zagitta/gpu-unlock/issues/298). It has
no settings page, unlocks every card unless a file on the flash drive is
edited, and fetches its package for a new kernel during the boot. It builds
its module from the kernel config and patches inside Unraid's own release,
where this repository relies on ich777's prepared trees.

## The settings page

Settings, User Utilities, GPU Unlock. The page answers two questions first,
what this boot did and whether the next boot is ready, and then lists the
five things that have to be true, in order, each with the one button that
completes it:

1. **Kernel module** for the kernel the next boot runs (the staged one after
   an Unraid update): *Fetch module*.
2. **Firmware**: *Generate firmware*. The page follows the generation through
   its phases with the log, without a reload, and you can leave it.
3. **Cards**: tick them in the list (model name, chip, PCI address, the
   driver holding the card now, this boot's result) and *Save selection*.
4. **Boot rule**: installed with the plugin; *Switch off* skips the unlock on
   the next boots without removing anything.
5. **Power cycle**.

Once all five are done the list folds away. The headline says so when a
card needs a full power off, and notices appear only when something else
needs attention: a staged Unraid update whose module is missing, firmware generated for an earlier
gpu_unlock, a conflicting modprobe rule, Safe Mode, a saved card address
that no longer exists. *Check now* does what the daily cron job does;
*Copy report* puts `gpu-unlock-ctl status` on the clipboard, fenced for a
GitHub issue. The page follows the WebGUI theme (black, white, azure, gray).

## Requirements

- Unraid 7.1.0 or newer (kernel 6.12 or newer). Tested kernels: whatever has a
  release in this repository; 7.3.4 (`6.18.58-Unraid`) is the first.
- A supported card and the Nvidia-Driver plugin: the hook runs when the
  `nvidia` module loads, so without the driver nothing triggers the unlock
  (and nothing would use the unlocked rate).
- Docker enabled, once, to generate the firmware (about 370 MB downloaded from
  download.nvidia.com: the driver installer and the kernel module source, each
  checked against a SHA-256 pinned in `versions.env`).
- About 120 MB free on the flash drive.

## Install

1. Plugins, Install Plugin, paste
   `https://github.com/tabilzad/gpu-unlock-unraid/releases/latest/download/gpu-unlock.plg`.
   The install fetches the module for your kernel and writes the modprobe
   rule. Nothing is loaded yet.
2. Settings, User Utilities, GPU Unlock, step 2, **Generate firmware**. Takes
   a few minutes; the page shows the phases and the log. (Or in a terminal:
   `gpu-unlock-ctl firmware`.)
3. On the same page, tick the card(s) to unlock, or "every supported card",
   and **Save selection**. The choice is kept on the flash drive and applies
   at the next boot. (The kernel command line still works and overrides the page:
   `gpu_unlock.targets=0000:01:00.0` on the boot entry in Main, Flash,
   Syslinux Configuration. `gpu-unlock-ctl targets set ...` does the same as
   the page from a terminal.)
4. Reboot. The module refuses a card the driver already initialised since
   power-on; a plain reboot usually resets the card (unlockGPU4Unraid
   observed this on two RTX 3080), and a full power off always does. If the
   page then says "power off required", shut down and power on.
5. The settings page shows each card's result (unlocked, failed with the
   module's reason, skipped) and the kernel log lines; success is
   `gpu_unlock: unlocked` for the card before `NVRM: loading NVIDIA`. A
   notification reports the outcome once per boot. `gpu-unlock-ctl status`
   shows the same in a terminal.

## Unraid updates and new kernels

The module must match the kernel exactly, so every Unraid release needs its own
build. The `Modules` workflow runs daily (`scripts/discover-kernels`): it
takes the kernels listed in `kernels.txt`, the kernel of every current stable
Unraid release (Unraid's release feed lists the releases and each release
note names its kernel) and every kernel ich777 has published a tree for that
is newer than the newest one released here, builds those that have no module
yet (a few per night), and attaches each to a release named after the kernel.
A new Unraid version is normally covered within a day of its release, often
before it: 6.18.60, the kernel of Unraid 7.3.5 and 7.4.0, was built six days
before they came out. Any other kernel, for example an older release
candidate, can be built by hand: Actions, Modules, Run workflow, with the
kernel version as input.

On the server, a missing module is fetched at three moments. Every minute, a
cron entry reads the kernel version of `/boot/bzimage`, which an Unraid
update replaces before the reboot, and fetches that kernel's module as soon
as it changes, then notifies you: apply the update, wait for the
notification (or click **Check now**), reboot, and the unlock carries over.
At every boot and daily, `gpu-unlock-ctl check` fetches whatever the running
and the staged kernel lack and verifies the firmware. When a boot's fetch
fails, as it does when the network is not up yet during the plugin phase, the
plugin keeps trying in the background for about an hour. So if you reboot
right after the update, the first boot into the new kernel runs locked, the
module arrives during that boot and a notification asks for one more power
cycle. If no build exists yet, you get a warning once per boot and the fetch
is tried again every half hour.

A new upstream gpu-unlock version is a plugin update: `versions.env` pins the
upstream commit, the Modules workflow rebuilds every kernel for the new
version (`force`), and the plugin replaces the module on the flash drive when
the pinned version changes. When the new version loads more firmware files
than the set on the flash drive holds, the page, `status` and `check` report
the firmware as incomplete and ask you to generate it again; the hook still
stages the old set meanwhile, so the cards whose files are there stay
unlocked.

## Disable, remove, recover

- **Disable for the next boots**: *Switch off* on the settings page or
  `gpu-unlock-ctl disable` (a marker file; `enable` undoes it). Clearing the
  targets, removing `gpu_unlock.targets=` from the boot entry if you used
  it, or booting Safe Mode also skips it.
- **Remove**: uninstall the plugin. The modprobe rule, hook, modules and cron
  job go; the firmware and settings stay under
  `/boot/config/plugins/gpu-unlock` until you delete the directory. Remove the
  command-line option too.
- **If a boot misbehaves**: edit the boot entry at the boot menu and delete
  `gpu_unlock.targets=...`, boot Safe Mode, or delete
  `config/modprobe.d/gpu-unlock.conf` from the flash drive on another machine.

## Command line

```
gpu-unlock-ctl status [--json]       what is staged, each card's result this boot, the cards
gpu-unlock-ctl targets [show | set all|ADDR,... | clear]   the cards to unlock
gpu-unlock-ctl check [--quiet]       fetch the module for the running and the staged kernel
gpu-unlock-ctl check --staged        the same for a staged Unraid update only (cron, every minute)
gpu-unlock-ctl retry                 keep fetching a missing module for an hour (post-install, in the background)
gpu-unlock-ctl fetch [KVER|--pending] [--force]
gpu-unlock-ctl firmware [--cache DIR] | firmware import DIR
gpu-unlock-ctl enable | disable
gpu-unlock-ctl report                notify once per boot what the unlock did
gpu-unlock-ctl hook-install          rewrite the rule, the hook copy and the cron job
gpu-unlock-ctl pending-kernel        the kernel /boot/bzimage will boot
gpu-unlock-ctl uninstall [--purge]
```

Settings file `/boot/config/plugins/gpu-unlock/gpu-unlock.cfg` (optional):
`FIRMWARE_IMAGE="registry.example/firmware-gen:tag"` to run a pre-built
generator image instead of building it locally, `RELEASE_BASE="https://..."`
to fetch modules from a fork.

## Building and developing

```sh
./scripts/dev-env --root make check          # lint (shellcheck, shfmt, php -l, escaping, node --check, xmllint, actionlint) and tests
./scripts/dev-env make build                 # dist/gpu-unlock-<version>.txz and a dev gpu-unlock.plg
./scripts/build-module --kver 6.18.58-Unraid # the module for one kernel (Docker; caches the ~300 MB tree)
make firmware-gen                            # build and run the on-box generator here, into dist/firmware
bash tests/preview.sh unlocked               # the settings page at http://127.0.0.1:8088/, without an Unraid server
```

The tests (`tests/`) run the real hook, control tool, install and remove
scripts against a fake root with a stub notifier, a fake `/proc/cmdline`, fake
PCI devices and a `file://` release base, and install the package with
Slackware's own pkgtools. The settings page is rendered by PHP against the
same fake root in every state it distinguishes, with hostile values in
everything the control tool reports, and its endpoints are called the way
php-fpm would. `tests/preview.sh` serves that page from PHP's built-in web
server with working buttons (scenarios: fresh, ready, unlocked, poweroff,
staged, firmware); the script that drives the page in the browser has no
automated test, the preview is how it is checked. Releases: tag `vX.Y.Z`; `release.yml` builds the
package, renders and lints the plg and publishes them. The plugin version shown
by Unraid is date based (`YYYY.MM.DD.N`), derived from the tag.

Layout: `src/` is the package tree rooted at `/`, `plugin/` the plg template
and Slackware description, `docker/` the module build, `scripts/` the build
tooling, `versions.env` the pinned upstream commit.

## Credits

[Zagitta/gpu-unlock](https://github.com/Zagitta/gpu-unlock) (the module and
the firmware generators), [ich777](https://github.com/ich777/unraid_kernel)
(prepared Unraid kernel trees), the Unraid report in gpu-unlock#55 and
[ampersandru/gpu-unlock-unraid](https://github.com/ampersandru/gpu-unlock-unraid)
(the modprobe hook approach).
