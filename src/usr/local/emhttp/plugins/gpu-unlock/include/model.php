<?php
/*
 * SPDX-License-Identifier: GPL-2.0-only
 * model.php: what the GPU Unlock page says, derived from the output of
 * `gpu-unlock-ctl status --json`. Pure: no I/O, no HTML. include/render.php
 * turns the result into markup.
 *
 *   gu_model(array $status): array
 *
 * The model answers the two questions the page exists for (what did this boot
 * do, and is the next boot ready) and lists the setup steps in the order they
 * have to happen, each with the one action that completes it.
 */
declare(strict_types=1);

require_once __DIR__ . '/ui.php';

/** The phases of a firmware generation, in order, with what the page calls them. */
const GU_FIRMWARE_PHASES = [
    'build' => 'Build the generator image',
    'download' => "Download NVIDIA's driver installer and kernel source (about 370 MB)",
    'extract' => 'Extract the firmware files',
    'install' => 'Verify them and write them to the flash drive',
];

/** A list from the status document, or [] when the key is missing or malformed. */
function gu_list(array $s, string $key): array
{
    return is_array($s[$key] ?? null) ? array_values($s[$key]) : [];
}

function gu_model(array $s): array
{
    $kernel = (string) ($s['kernel'] ?? '');
    $pending = (string) ($s['pending_kernel'] ?? '');
    $mv = (string) ($s['module_version'] ?? '');
    $nv = (string) ($s['nv'] ?? '');
    $targets = (string) ($s['targets'] ?? '');
    $source = (string) ($s['targets_source'] ?? 'none');
    $all = $targets === 'all';
    $selected = ($targets === '' || $all) ? [] : explode(',', $targets);
    $locked_by_cmdline = $source === 'cmdline';

    $module_now = !empty($s['module_present']);
    $module_pending = !empty($s['pending_module_present']);
    // An Unraid update replaces /boot/bzimage before the reboot: the next
    // boot runs the staged kernel, so its module is the one that counts.
    $next_kernel = $pending !== '' ? $pending : $kernel;
    $module_next = $pending !== '' ? $module_pending : $module_now;

    $fw = (string) ($s['firmware_state'] ?? (!empty($s['firmware_present']) ? 'present' : 'missing'));
    $fw_missing = gu_list($s, 'firmware_missing');
    $fw_files = (int) ($s['firmware_files'] ?? 0);
    $job = !empty($s['firmware_job']);
    $job_rc = (string) ($s['firmware_job_rc'] ?? '');
    $job_failed = !$job && $job_rc !== '' && $job_rc !== '0';
    // The hook stages a set that lacks files too, so the cards whose files
    // are there are still unlocked: usable, with a caveat.
    $fw_usable = $fw === 'present' || $fw === 'incomplete';

    $hook = (string) ($s['hook_status'] ?? '');
    $hook_ran = str_starts_with($hook, 'loaded:');
    $conflict = (string) ($s['hook_conflict'] ?? '');
    $rule = !empty($s['hook_installed']);
    $disabled = !empty($s['disabled']);
    $safe = !empty($s['safe_mode']);
    $power_off = !empty($s['power_off_required']);

    $verdicts = [];
    $n = ['unlocked' => 0, 'failed' => 0, 'skipped' => 0, 'pending' => 0];
    foreach (gu_list($s, 'verdicts') as $v) {
        if (!is_array($v)) {
            continue;
        }
        $verdicts[(string) ($v['address'] ?? '')] = $v;
        $state = (string) ($v['state'] ?? '');
        $n[isset($n[$state]) ? $state : 'failed']++;
    }

    // ---- the cards ---------------------------------------------------------
    $rows = [];
    $present = [];
    $supported = 0;
    foreach (gu_list($s, 'cards') as $c) {
        if (!is_array($c)) {
            continue;
        }
        $addr = (string) ($c['address'] ?? '');
        $present[] = $addr;
        $ok = !empty($c['supported']);
        $supported += $ok ? 1 : 0;
        $driver = (string) ($c['driver'] ?? '');
        $v = $verdicts[$addr] ?? null;
        $result = null;
        if ($v !== null) {
            $reason = (string) ($v['reason'] ?? '');
            $result = match ((string) ($v['state'] ?? '')) {
                'unlocked' => ['tone' => 'ok', 'label' => 'unlocked', 'reason' => ''],
                'skipped' => ['tone' => 'neutral', 'label' => 'skipped', 'reason' => $reason],
                'pending' => $hook_ran
                    ? ['tone' => 'warn', 'label' => 'no result', 'reason' => $reason]
                    : ['tone' => 'neutral', 'label' => 'at the next boot', 'reason' => ''],
                default => ['tone' => 'bad', 'label' => 'failed', 'reason' => $reason],
            };
            $result['power_off'] = !empty($v['power_off']);
        } elseif ($hook_ran && $ok) {
            $result = ['tone' => 'neutral', 'label' => 'not chosen', 'reason' => '', 'power_off' => false];
        }
        $name = trim((string) ($c['name'] ?? ''));
        $rows[] = [
            'address' => $addr,
            'name' => $name !== '' ? $name : 'NVIDIA card',
            'device' => '10de:' . preg_replace('/^0x/', '', (string) ($c['device'] ?? '')),
            'chip' => (string) ($c['chip'] ?? ''),
            'experimental' => !empty($c['experimental']),
            'supported' => $ok,
            'chosen' => $ok && ($all || in_array($addr, $selected, true)),
            'driver' => $driver === '' ? 'none' : $driver,
            // A card another driver holds at boot (vfio-pci for a VM) is left alone by the module.
            'held' => $driver !== '' && $driver !== 'none' && $driver !== 'nvidia',
            'result' => $result,
        ];
    }
    $gone = array_values(array_diff($selected, $present));

    // ---- is the next boot ready, and if not, what is in the way ------------
    $blocker = '';
    if (!$module_next) {
        $blocker = "no module for kernel $next_kernel is on the flash drive";
    } elseif (!$fw_usable && $job) {
        $blocker = 'the firmware is being generated';
    } elseif ($fw === 'missing') {
        $blocker = 'the firmware is not generated yet';
    } elseif (!$fw_usable) {
        $blocker = 'the firmware on the flash drive fails its checksums';
    } elseif ($targets === '') {
        $blocker = 'no card is chosen';
    } elseif ($conflict !== '') {
        $blocker = 'another modprobe rule takes over the nvidia load';
    } elseif (!$rule) {
        $blocker = 'the boot rule is not installed';
    } elseif ($disabled) {
        $blocker = 'the unlock is switched off';
    }
    $ready = $blocker === '';
    $done_now = $hook_ran && $n['unlocked'] > 0 && $n['pending'] === 0 && $n['failed'] === 0 && !$power_off;

    // ---- headline ----------------------------------------------------------
    if ($power_off) {
        $headline = ['bad', 'Power off required. Shut the server down, wait a few seconds and power it on; a reboot is not enough for this card.'];
    } elseif ($n['failed'] > 0) {
        $headline = ['bad', gu_count($n['failed'], 'card', 'cards') . ' failed to unlock this boot. The reason is next to the card below.'];
    } elseif ($done_now) {
        $headline = ['ok', gu_count($n['unlocked'], 'card', 'cards') . ' unlocked this boot.'
            . ($ready ? '' : " The next boot is not ready: $blocker.")];
    } elseif ($ready) {
        $headline = ['info', 'Ready. The unlock runs the next time the server is powered on.'];
    } else {
        $headline = ['warn', "Not ready yet: $blocker."];
    }

    // ---- notices -----------------------------------------------------------
    // What needs attention beyond the headline (a required power off is the headline).
    $notices = [];
    if ($conflict !== '') {
        $notices[] = ['tone' => 'bad', 'text' => "Another file carries an 'install nvidia' modprobe rule: $conflict. Only one such rule can run, so the unlock rule was not written. Remove that file, then install the boot rule in step 4."];
    }
    if ($safe) {
        $notices[] = ['tone' => 'warn', 'text' => 'Unraid is in Safe Mode: the boot rule does nothing, and neither do third-party drivers.'];
    }
    if ($disabled) {
        $notices[] = ['tone' => 'warn', 'text' => 'The unlock is switched off for the next boots. Everything stays on the flash drive.',
            'action' => ['enable', 'Enable', 'play', 'sm']];
    }
    if ($locked_by_cmdline) {
        $notices[] = ['tone' => 'info', 'text' => "gpu_unlock.targets=$targets on the kernel command line decides the cards, so the selection below is read-only. Remove it from the boot entry (Main, Flash, Syslinux Configuration) to choose here."];
    }
    if ($pending !== '' && !$module_pending) {
        $notices[] = ['tone' => 'warn', 'text' => "An Unraid update is staged and the next boot runs kernel $pending. Its module is not on the flash drive yet: fetch it before you reboot, or that boot runs locked.",
            'action' => ['fetch-pending', 'Fetch module', 'download', 'sm']];
    }
    if ($fw === 'incomplete' && !$job) {
        $notices[] = ['tone' => 'warn', 'text' => 'The firmware on the flash drive was generated for an earlier gpu_unlock and lacks '
            . gu_count(count($fw_missing), 'file', 'files') . " that $mv loads. Cards whose files are there are still unlocked; generate it again in step 2 for the rest."];
    }
    if ($gone !== []) {
        $notices[] = ['tone' => 'warn', 'text' => 'The saved selection names ' . implode(', ', $gone) . ', which is not an NVIDIA card in this server (cards change address when they move slots). Tick the cards again and save.'];
    }
    if ($hook === '' && empty($s['nvidia_loaded']) && empty($s['module_loaded'])) {
        $notices[] = ['tone' => 'info', 'text' => 'The NVIDIA driver is not loaded. The unlock runs at the moment it loads, so the Nvidia Driver plugin has to be installed.'];
    }
    $free = $s['flash_free_kb'] ?? null;
    if (is_int($free) && $free < 153600 && $fw !== 'present') {
        $notices[] = ['tone' => 'warn', 'text' => 'Only ' . gu_kib($free) . ' are free on the flash drive. The firmware takes about 110 MB.'];
    }

    // ---- summary cards -----------------------------------------------------
    if ($power_off) {
        $boot = ['bad', 'Power off', 'required before a card can be unlocked'];
    } elseif ($n['failed'] > 0) {
        $boot = ['bad', $n['failed'] . ' failed', $n['unlocked'] . ' unlocked'];
    } elseif ($done_now) {
        $boot = ['ok', $n['unlocked'] . ' unlocked', $n['skipped'] > 0 ? $n['skipped'] . ' skipped' : 'before the NVIDIA driver loaded'];
    } elseif ($hook_ran) {
        $boot = ['warn', 'No result', 'the kernel log has none for the chosen cards'];
    } elseif (str_starts_with($hook, 'skipped:')) {
        $boot = ['neutral', 'Skipped', trim(substr($hook, 8))];
    } elseif (str_starts_with($hook, 'failed:')) {
        $boot = ['bad', 'Not loaded', trim(substr($hook, 7))];
    } elseif (!empty($s['module_loaded'])) {
        $boot = ['info', 'Loaded', 'by hand, not by the boot rule'];
    } else {
        $boot = ['neutral', 'Not run', 'the boot rule runs when the NVIDIA driver loads'];
    }
    if ($ready) {
        $next = [$fw === 'incomplete' ? 'warn' : 'ok', 'Ready',
            $fw === 'incomplete' ? 'firmware incomplete: some cards may fail' : "kernel $next_kernel" . ($pending !== '' ? ', the staged update' : '')];
    } else {
        $off = $blocker === 'the unlock is switched off';
        $next = [$off ? 'neutral' : 'warn', $off ? 'Switched off' : 'Not ready', $blocker];
    }
    if ($supported === 0) {
        $chosen = ['neutral', '0', 'no card gpu_unlock supports was found'];
    } elseif ($targets === '') {
        $chosen = ['warn', '0 of ' . $supported, 'none chosen yet'];
    } else {
        $picked = $all ? $supported : count(array_filter($rows, static fn (array $r): bool => $r['chosen']));
        $chosen = ['ok', $all ? 'All' : $picked . ' of ' . $supported,
            $locked_by_cmdline ? 'from the kernel command line' : ($all ? 'every supported card' : 'chosen on this page')];
    }
    $tiles = [
        ['label' => 'This boot', 'tone' => $boot[0], 'value' => $boot[1], 'sub' => $boot[2]],
        ['label' => 'Next boot', 'tone' => $next[0], 'value' => $next[1], 'sub' => $next[2]],
        ['label' => 'Cards chosen', 'tone' => $chosen[0], 'value' => $chosen[1], 'sub' => $chosen[2]],
        ['label' => 'gpu_unlock', 'tone' => 'neutral', 'value' => $mv !== '' ? $mv : 'unknown', 'sub' => "NVIDIA firmware $nv"],
    ];

    // ---- setup steps, in the order they have to happen ---------------------
    $steps = [];

    if ($pending === '') {
        $steps[] = $module_now
            ? ['key' => 'module', 'title' => 'Kernel module', 'tone' => 'ok', 'text' => "gpu_unlock $mv for $kernel is on the flash drive."]
            : ['key' => 'module', 'title' => 'Kernel module', 'tone' => 'warn',
                'text' => "No module for $kernel on the flash drive. A build for every Unraid kernel appears on GitHub within a day of its release.",
                'actions' => [['fetch', 'Fetch module', 'download', 'primary']]];
    } elseif ($module_pending) {
        $steps[] = ['key' => 'module', 'title' => 'Kernel module', 'tone' => 'ok',
            'text' => "gpu_unlock $mv is on the flash drive for $pending, the staged Unraid update the next boot runs"
                . ($module_now ? ", and for $kernel." : '.')];
    } else {
        $steps[] = ['key' => 'module', 'title' => 'Kernel module', 'tone' => 'warn',
            'text' => "The next boot runs $pending (a staged Unraid update) and no module for it is on the flash drive"
                . ($module_now ? ". The one for $kernel is there." : '.'),
            'actions' => [['fetch-pending', "Fetch module for $pending", 'download', 'primary']]];
    }

    $phases = [];
    if ($job || $job_failed) {
        $order = array_keys(GU_FIRMWARE_PHASES);
        $at = array_search((string) ($s['firmware_phase'] ?? ''), $order, true);
        $at = $at === false ? ((string) ($s['firmware_phase'] ?? '') === 'done' ? count($order) : 0) : $at;
        foreach ($order as $i => $key) {
            $phases[] = [
                'label' => GU_FIRMWARE_PHASES[$key],
                'state' => $i < $at ? 'done' : ($i > $at ? 'todo' : ($job ? 'active' : 'failed')),
            ];
        }
    }
    $fw_step = ['key' => 'firmware', 'title' => 'Firmware', 'phases' => $phases, 'log' => $job || $job_failed ? gu_list($s, 'firmware_log') : []];
    if ($job) {
        $fw_step += ['tone' => 'info', 'text' => 'Generating. This takes a few minutes; you can leave the page.'];
    } elseif ($fw === 'present') {
        $fw_step += ['tone' => 'ok', 'text' => "Firmware $nv is on the flash drive" . ($fw_files > 0 ? ", all $fw_files files." : '.')
            . ($job_failed ? ' Generating it again failed and changed nothing; the log below says why.' : '')];
    } elseif ($fw === 'missing') {
        $fw_step += ['tone' => $job_failed ? 'bad' : 'warn',
            'text' => ($job_failed ? 'The last generation failed; the log below says why. ' : '')
                . "Not generated yet. The module needs NVIDIA's own firmware, which is built on this server: a Docker container downloads about 370 MB from NVIDIA, checks it against pinned checksums and writes about 110 MB to the flash drive.",
            'actions' => [['firmware', 'Generate firmware', 'cog', 'primary']]];
    } elseif ($fw === 'incomplete') {
        $fw_step += ['tone' => 'warn',
            'text' => ($job_failed ? 'The last generation failed; the log below says why. ' : '')
                . 'Generated for an earlier gpu_unlock: ' . gu_count(count($fw_missing), 'file is', 'files are') . ' missing. Generate it again.',
            'actions' => [['firmware', 'Generate firmware again', 'cog', 'primary']]];
    } else {
        $fw_step += ['tone' => 'bad',
            'text' => ($job_failed ? 'The last generation failed; the log below says why. ' : '')
                . 'The files on the flash drive fail their checksums, so the boot rule skips them. Generate the firmware again.',
            'actions' => [['firmware', 'Generate firmware again', 'cog', 'primary']]];
    }
    $steps[] = $fw_step;

    if ($locked_by_cmdline) {
        $steps[] = ['key' => 'cards', 'title' => 'Cards', 'tone' => 'ok', 'text' => "Set on the kernel command line: $targets."];
    } elseif ($targets === '') {
        $steps[] = ['key' => 'cards', 'title' => 'Cards', 'tone' => 'warn',
            'text' => $supported > 0 ? 'No card is chosen. Tick the cards to unlock in the list below, then save.' : 'No card that gpu_unlock supports was found in this server.'];
    } else {
        $steps[] = ['key' => 'cards', 'title' => 'Cards', 'tone' => $gone === [] ? 'ok' : 'warn',
            'text' => $all ? 'Every supported card is unlocked, also ones added later.' : gu_count(count($selected), 'card', 'cards') . ' chosen: ' . implode(', ', $selected) . '.'];
    }

    if ($conflict !== '') {
        $steps[] = ['key' => 'rule', 'title' => 'Boot rule', 'tone' => 'bad',
            'text' => "Not written: $conflict already takes over the nvidia load. Remove that file first.",
            'actions' => [['hook-install', 'Install boot rule', 'save', 'primary']]];
    } elseif (!$rule) {
        $steps[] = ['key' => 'rule', 'title' => 'Boot rule', 'tone' => 'warn',
            'text' => 'The modprobe rule that runs the unlock right before the NVIDIA driver loads is not on the flash drive.',
            'actions' => [['hook-install', 'Install boot rule', 'save', 'primary']]];
    } elseif ($disabled) {
        $steps[] = ['key' => 'rule', 'title' => 'Boot rule', 'tone' => 'warn',
            'text' => 'Installed, but the unlock is switched off for the next boots.',
            'actions' => [['enable', 'Enable', 'play', 'primary']]];
    } else {
        $steps[] = ['key' => 'rule', 'title' => 'Boot rule', 'tone' => 'ok',
            'text' => 'Installed. It runs the unlock right before the NVIDIA driver loads, at every boot, and never holds the driver back.'];
    }

    if ($power_off) {
        $steps[] = ['key' => 'power', 'title' => 'Power cycle', 'tone' => 'bad',
            'text' => 'A full power off is needed: the card reported that the NVIDIA driver had already started it. NVIDIA drives it locked until then.'];
    } elseif ($n['failed'] > 0) {
        $steps[] = ['key' => 'power', 'title' => 'Power cycle', 'tone' => 'bad',
            'text' => gu_count($n['failed'], 'card', 'cards') . ' failed this boot. The reason is next to the card below; a full power off clears most of them.'];
    } elseif ($done_now && $ready) {
        $steps[] = ['key' => 'power', 'title' => 'Power cycle', 'tone' => 'ok',
            'text' => 'Done: ' . gu_count($n['unlocked'], 'card was', 'cards were') . ' unlocked this boot, and every boot repeats it.'];
    } elseif ($ready) {
        $steps[] = ['key' => 'power', 'title' => 'Power cycle', 'tone' => 'info',
            'text' => 'Shut the server down and start it again. A plain reboot usually works too; this page says so when a card needs the full power off. The unlock cannot run on a card the NVIDIA driver already started.'];
    } else {
        $steps[] = ['key' => 'power', 'title' => 'Power cycle', 'tone' => 'neutral',
            'text' => 'Once the steps above are done: shut the server down and start it again.'];
    }
    // The step to act on: the first one that is neither done nor waiting.
    $current = null;
    foreach ($steps as $i => $step) {
        if ($step['tone'] !== 'ok' && $step['tone'] !== 'neutral') {
            $current = $i;
            break;
        }
    }
    foreach ($steps as $i => $step) {
        $steps[$i]['current'] = $i === $current;
        $steps[$i]['actions'] ??= [];
    }

    // ---- this boot, the flash drive ----------------------------------------
    if ($hook !== '') {
        $hook_text = $hook;
    } elseif (!empty($s['module_loaded'])) {
        $hook_text = 'gpu_unlock is loaded, but not by the boot rule (no record of it this boot).';
    } else {
        $hook_text = 'The boot rule has not run this boot. That is expected until the first boot after the install. Still so after a reboot means the NVIDIA driver did not load.';
    }
    $modules = [];
    foreach (gu_list($s, 'modules') as $m) {
        if (is_array($m)) {
            $modules[] = ['kernel' => (string) ($m['kernel'] ?? ''), 'ok' => !empty($m['ok'])];
        }
    }

    return [
        'headline' => ['tone' => $headline[0], 'text' => $headline[1]],
        'notices' => $notices,
        'tiles' => $tiles,
        'steps' => $steps,
        'rows' => $rows,
        'supported' => $supported,
        'targets' => $targets,
        'all' => $all,
        'locked' => $locked_by_cmdline,
        'ready' => $ready,
        'disabled' => $disabled,
        'job' => $job,
        'job_rc' => $job_rc,
        'boot' => [
            'hook' => $hook_text,
            'module_loaded' => !empty($s['module_loaded']),
            'nvidia_loaded' => !empty($s['nvidia_loaded']),
            'log' => gu_list($s, 'kernel_log'),
        ],
        'flash' => [
            'modules' => $modules,
            'firmware' => $fw,
            'free' => gu_kib($free),
        ],
        'versions' => [
            'plugin' => (string) ($s['plugin_version'] ?? ''),
            'module' => $mv,
            'nv' => $nv,
            'kernel' => $kernel,
            'pending' => $pending,
        ],
        'releases' => (string) ($s['releases'] ?? ''),
    ];
}
