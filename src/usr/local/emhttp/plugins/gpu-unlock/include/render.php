<?php
/*
 * SPDX-License-Identifier: GPL-2.0-only
 * render.php: the markup of the GPU Unlock page.
 *
 *   gu_render(array $status): string
 *
 * One function renders everything inside the page's root element, so the
 * page (GpuUnlock.page) and the refresh endpoint (include/view.php) cannot
 * drift apart: the script swaps the root's content for a fresh render after
 * every action and while a firmware generation runs. Every value goes through
 * gu_h(); the helpers in include/ui.php escape what they are given.
 */
declare(strict_types=1);

require_once __DIR__ . '/model.php';

function gu_render(array $status): string
{
    ob_start();
    if ($status === []) {
        gu_render_silent();
        return (string) ob_get_clean();
    }
    $m = gu_model($status);
    ?>
<div class="gu-view" data-job="<?= gu_h($m['job'] ? '1' : '0') ?>" data-job-rc="<?= gu_h($m['job_rc']) ?>" data-targets="<?= gu_h($m['targets']) ?>" data-locked="<?= gu_h($m['locked'] ? '1' : '0') ?>">
<?php
    gu_render_hero($m);
    gu_render_notices($m['notices']);
    gu_render_tiles($m['tiles']);
    gu_render_steps($m['steps']);
    gu_render_cards($m);
    gu_render_boot($m);
    gu_render_flash($m);
    ?>
</div>
<?php
    return (string) ob_get_clean();
}

/** The control tool did not answer: say so, and keep a way to try again. */
function gu_render_silent(): void
{
    ?>
<div class="gu-view" data-job="0" data-job-rc="" data-targets="" data-locked="1">
<div class="gu-hero" data-tone="bad">
<div class="gu-hero-mark"><?= gu_icon('unlock') ?></div>
<div class="gu-hero-copy">
<h2 class="gu-hero-title">gpu-unlock-ctl did not answer, so there is nothing to show.</h2>
</div>
<div class="gu-hero-actions"><button type="button" class="gu-btn" data-refresh="1"><?= gu_icon('refresh') ?><span>Try again</span></button></div>
</div>
<div id="gu-result" class="gu-result gu-hidden" role="status" aria-live="polite"></div>
<div class="gu-notices"><div class="gu-notice" data-tone="bad"><?= gu_icon('warning') ?><div class="gu-notice-text">Reinstall the plugin from the Plugins tab, or run <code>gpu-unlock-ctl status</code> in a terminal to see the error.</div></div></div>
</div>
<?php
}

function gu_render_hero(array $m): void
{
    $v = $m['versions'];
    ?>
<div class="gu-hero" data-tone="<?= gu_h(gu_tone($m['headline']['tone'])) ?>">
<div class="gu-hero-mark"><?= gu_icon('unlock') ?></div>
<div class="gu-hero-copy">
<h2 class="gu-hero-title"><?= gu_h($m['headline']['text']) ?></h2>
<p class="gu-hero-fine">Full FP16 and BF16 tensor rate for GeForce RTX 30 series cards, and experimentally RTX 20 and 40, with <a href="https://github.com/Zagitta/gpu-unlock" target="_blank" rel="noopener">Zagitta/gpu-unlock</a> <?= gu_h($v['module']) ?>.<?php if ($v['plugin'] !== '' && $v['plugin'] !== 'unknown'): ?> Plugin <?= gu_h($v['plugin']) ?>.<?php endif; ?> Not affiliated with NVIDIA, Lime Technology or the gpu-unlock authors.</p>
</div>
<div class="gu-hero-actions">
<?= gu_button('check', 'Check now', 'refresh', '', [], 'Fetch a missing module for the running and the staged kernel, and check the firmware. The same check runs daily.') ?>
<?= gu_button('diagnostics', 'Copy report', 'copy', '', [], 'Copy what this page knows as text, ready to paste into a GitHub issue.') ?>
<?php if ($m['disabled']): ?>
<?= gu_button('enable', 'Enable', 'play', 'primary') ?>
<?php else: ?>
<?= gu_button('disable', 'Switch off', 'pause', '', [], 'Skip the unlock on the next boots. Everything stays on the flash drive.') ?>
<?php endif; ?>
</div>
</div>
<div id="gu-result" class="gu-result gu-hidden" role="status" aria-live="polite"></div>
<?php
}

function gu_render_notices(array $notices): void
{
    if ($notices === []) {
        return;
    }
    ?>
<div class="gu-notices">
<?php foreach ($notices as $n): $tone = gu_tone($n['tone']); ?>
<div class="gu-notice" data-tone="<?= gu_h($tone) ?>"><?= gu_icon($tone === 'info' ? 'info' : 'warning') ?><div class="gu-notice-text"><?= gu_h($n['text']) ?></div><?php if (isset($n['action'])): ?><?= gu_button($n['action'][0], $n['action'][1], $n['action'][2], $n['action'][3]) ?><?php endif; ?></div>
<?php endforeach; ?>
</div>
<?php
}

function gu_render_tiles(array $tiles): void
{
    ?>
<div class="gu-cards">
<?php foreach ($tiles as $t): ?>
<div class="gu-card" data-tone="<?= gu_h(gu_tone($t['tone'])) ?>">
<div class="gu-card-label"><?= gu_h($t['label']) ?></div>
<div class="gu-card-value"><?= gu_h($t['value']) ?></div>
<div class="gu-card-sub"><?= gu_h($t['sub']) ?></div>
</div>
<?php endforeach; ?>
</div>
<?php
}

/** The marker of a setup step: a tick when done, a warning when broken, else its number. */
function gu_step_mark(string $tone, int $number): string
{
    if ($tone === 'ok') {
        return gu_icon('check');
    }
    return $tone === 'bad' ? gu_icon('warning') : (string) $number;
}

/** The class of a kernel log line: the per-card verdict lines stand out. */
function gu_log_class(string $line): string
{
    if (str_contains($line, 'gpu_unlock: unlocked')) {
        return 'gu-log-ok';
    }
    return preg_match('/failed|power off/', $line) === 1 ? 'gu-log-bad' : 'gu-log-line';
}

function gu_render_steps(array $steps): void
{
    $states = ['ok' => 'done', 'warn' => 'to do', 'bad' => 'problem', 'info' => 'now', 'neutral' => 'later'];
    // With every step done the list folds away: the cards and this boot's
    // result are what the page is opened for from then on. The key carries
    // the number of steps done, so the page script keeps the list as the user
    // left it across refreshes until a step completes.
    $tones = array_column($steps, 'tone');
    $done = count(array_keys($tones, 'ok', true));
    $overall = 'ok';
    foreach (['info', 'warn', 'bad'] as $t) {
        if (in_array($t, $tones, true)) {
            $overall = $t;
        }
    }
    ?>
<details class="gu-section gu-setup" data-key="setup-<?= gu_h($done) ?>"<?= gu_h($done < count($steps) ? ' open' : '') ?>>
<summary><span class="gu-section-title"><?= gu_icon('list') ?>Setup</span><?= gu_badge($done . ' of ' . count($steps) . ' done', $overall) ?></summary>
<p class="gu-section-desc">Five things have to be true for a card to be unlocked. Each step shows where it stands and the one button that completes it.</p>
<ol class="gu-steps">
<?php foreach ($steps as $i => $s): $tone = gu_tone($s['tone']); $running = $s['key'] === 'firmware' && $tone === 'info'; ?>
<li class="gu-step<?= gu_h($s['current'] ? ' gu-step-current' : '') ?>" data-tone="<?= gu_h($tone) ?>" data-step="<?= gu_h($s['key']) ?>">
<div class="gu-step-mark<?= gu_h($running ? ' gu-spin' : '') ?>"><?= gu_step_mark($tone, $i + 1) ?></div>
<div class="gu-step-body">
<div class="gu-step-head"><span class="gu-step-title"><?= gu_h($s['title']) ?></span><?= gu_badge($running ? 'running' : $states[$tone], $tone) ?></div>
<p class="gu-step-text"><?= gu_h($s['text']) ?></p>
<?php if (!empty($s['phases'])): ?>
<ul class="gu-phases">
<?php foreach ($s['phases'] as $p): ?>
<li class="gu-phase" data-state="<?= gu_h($p['state']) ?>"><?= gu_h($p['label']) ?></li>
<?php endforeach; ?>
</ul>
<?php endif; ?>
<?php if (!empty($s['log'])): ?>
<details class="gu-details" data-key="fwlog" open><summary>Log</summary><pre class="gu-log" id="gu-fwlog"><?= gu_h(implode("\n", array_map('strval', $s['log']))) ?></pre></details>
<?php endif; ?>
</div>
<?php if ($s['actions'] !== []): ?>
<div class="gu-step-actions"><?php foreach ($s['actions'] as $a): ?><?= gu_button($a[0], $a[1], $a[2], $a[3]) ?><?php endforeach; ?></div>
<?php endif; ?>
</li>
<?php endforeach; ?>
</ol>
</details>
<?php
}

function gu_render_cards(array $m): void
{
    $locked = $m['locked'];
    ?>
<div class="gu-section" id="gu-cards">
<div class="gu-section-head">
<div class="gu-section-copy">
<h3 class="gu-section-title"><?= gu_icon('chip') ?>NVIDIA cards</h3>
<p class="gu-section-desc">Tick the cards to unlock, then save. The choice is kept on the flash drive and applies at the next boot; nothing changes on the running system. A card passed through to a VM is left alone.</p>
</div>
</div>
<?php if ($m['rows'] === []): ?>
<div class="gu-empty"><?= gu_icon('chip') ?><p class="gu-empty-title">No NVIDIA card found</p><p class="gu-empty-msg">This server shows no NVIDIA display controller on the PCI bus. Check that the card is seated and powered, then open this page again.</p></div>
<?php else: ?>
<table class="gu-table">
<thead><tr><th class="gu-col-pick">Unlock</th><th>Card</th><th>Chip</th><th>Driver now</th><th>This boot</th></tr></thead>
<tbody>
<?php foreach ($m['rows'] as $r): ?>
<tr class="gu-row<?= gu_h($r['supported'] ? '' : ' gu-row-off') ?>">
<td class="gu-col-pick"><?php if ($r['supported']): ?><input type="checkbox" class="gu-pick" value="<?= gu_h($r['address']) ?>" aria-label="Unlock <?= gu_h($r['name']) ?> at <?= gu_h($r['address']) ?>"<?= gu_h($r['chosen'] ? ' checked' : '') ?><?= gu_h($locked ? ' disabled' : '') ?>><?php endif; ?></td>
<td><div class="gu-card-name"><?= gu_h($r['name']) ?></div><div class="gu-card-id"><span class="gu-mono"><?= gu_h($r['address']) ?></span><span class="gu-mono"><?= gu_h($r['device']) ?></span></div></td>
<td data-label="Chip"><?php if ($r['supported']): ?><span><?= gu_h($r['chip']) ?></span><?php if ($r['experimental']): ?> <?= gu_badge('experimental', 'warn', 'Upstream marks Turing and Ada Lovelace support experimental. Please report what happens.') ?><?php endif; ?><?php else: ?><?= gu_badge('not supported', 'neutral', 'gpu_unlock ' . $m['versions']['module'] . ' does not handle this device id.') ?><?php endif; ?></td>
<td data-label="Driver now"><?php if ($r['held']): ?><?= gu_badge($r['driver'], 'info', 'Another driver holds this card (a VM passthrough does that). The module leaves such a card alone.') ?><?php else: ?><span><?= gu_h($r['driver']) ?></span><?php endif; ?></td>
<td data-label="This boot"><?php if ($r['result'] !== null): ?><?= gu_badge($r['result']['label'], $r['result']['tone']) ?><?php if ($r['result']['reason'] !== ''): ?> <span class="gu-reason"><?= gu_h($r['result']['reason']) ?></span><?php endif; ?><?php if ($r['result']['power_off']): ?> <?= gu_badge('power off required', 'bad') ?><?php endif; ?><?php endif; ?></td>
</tr>
<?php endforeach; ?>
</tbody>
</table>
<?php if ($m['supported'] > 0): ?>
<div class="gu-pickbar">
<label class="gu-all"><input type="checkbox" id="gu-all"<?= gu_h($m['all'] ? ' checked' : '') ?><?= gu_h($locked ? ' disabled' : '') ?>><span>Every supported card, also ones added later</span></label>
<span class="gu-pick-hint" id="gu-pick-hint"></span>
<?php if (!$locked): ?>
<button type="button" class="gu-btn gu-btn-primary" id="gu-save" data-action="save-targets" disabled><?= gu_icon('save') ?><span>Save selection</span></button>
<?php endif; ?>
</div>
<?php endif; ?>
<?php endif; ?>
</div>
<?php
}

function gu_render_boot(array $m): void
{
    $b = $m['boot'];
    ?>
<div class="gu-section">
<div class="gu-section-head">
<div class="gu-section-copy">
<h3 class="gu-section-title"><?= gu_icon('pulse') ?>This boot</h3>
<p class="gu-section-desc">What the boot rule did when the NVIDIA driver loaded. Success is <code>gpu_unlock: unlocked</code> for the card before <code>NVRM: loading NVIDIA</code>.</p>
</div>
</div>
<div class="gu-kv">
<div class="gu-k">Boot rule</div>
<div class="gu-v"><?= gu_h($b['hook']) ?></div>
<div class="gu-k">gpu_unlock module</div>
<div class="gu-v"><?= gu_badge($b['module_loaded'] ? 'loaded' : 'not loaded', $b['module_loaded'] ? 'ok' : 'neutral') ?></div>
<div class="gu-k">NVIDIA driver</div>
<div class="gu-v"><?= gu_badge($b['nvidia_loaded'] ? 'loaded' : 'not loaded', $b['nvidia_loaded'] ? 'ok' : 'neutral') ?></div>
</div>
<?php if ($b['log'] !== []): ?>
<details class="gu-details" data-key="klog"><summary>Kernel log, <?= gu_h(gu_count(count($b['log']), 'line', 'lines')) ?></summary><pre class="gu-log"><?php foreach ($b['log'] as $line): $line = (string) $line; ?><span class="<?= gu_h(gu_log_class($line)) ?>"><?= gu_h($line) ?></span>
<?php endforeach; ?></pre></details>
<?php endif; ?>
</div>
<?php
}

function gu_render_flash(array $m): void
{
    $f = $m['flash'];
    $v = $m['versions'];
    $fw_tone = ['present' => 'ok', 'missing' => 'warn', 'incomplete' => 'warn'][$f['firmware']] ?? 'bad';
    ?>
<div class="gu-section">
<div class="gu-section-head">
<div class="gu-section-copy">
<h3 class="gu-section-title"><?= gu_icon('drive') ?>On the flash drive</h3>
<p class="gu-section-desc">Everything the boot needs lives under <code>/boot/config/plugins/gpu-unlock</code>, so a boot never waits for the network. The same facts as <code>gpu-unlock-ctl status</code> in a terminal.</p>
</div>
<div class="gu-toolbar">
<?= gu_button('fetch', 'Fetch module', 'download', 'sm', [], 'Download the module built for the running kernel from the GitHub release.') ?>
<?php if (!$m['job']): ?>
<?= gu_button('firmware', 'Generate firmware', 'cog', 'sm', [], 'Generate the firmware again with Docker: about 370 MB from NVIDIA, checked against pinned checksums.') ?>
<?php endif; ?>
<?= gu_button('hook-install', 'Rewrite boot rule', 'save', 'sm', [], 'Write the modprobe rule, the hook copy and the daily check again.') ?>
</div>
</div>
<div class="gu-kv">
<div class="gu-k">Running kernel</div>
<div class="gu-v"><span class="gu-mono"><?= gu_h($v['kernel']) ?></span></div>
<?php if ($v['pending'] !== ''): ?>
<div class="gu-k">Staged update</div>
<div class="gu-v"><span class="gu-mono"><?= gu_h($v['pending']) ?></span><span>the next boot runs it</span></div>
<?php endif; ?>
<div class="gu-k">Modules</div>
<div class="gu-v"><?php if ($f['modules'] === []): ?><span>none</span><?php else: ?><?php foreach ($f['modules'] as $mod): ?><span class="gu-mono"><?= gu_h($mod['kernel']) ?></span><?php if (!$mod['ok']): ?><?= gu_badge('damaged', 'bad') ?><?php endif; ?><?php endforeach; ?><?php endif; ?></div>
<div class="gu-k">Firmware</div>
<div class="gu-v"><span>NVIDIA <?= gu_h($v['nv']) ?></span><?= gu_badge($f['firmware'], $fw_tone) ?></div>
<div class="gu-k">Free space</div>
<div class="gu-v"><?= gu_h($f['free']) ?></div>
</div>
<p class="gu-help">After an Unraid update, click Check now before you reboot: it fetches the module for the new kernel in advance, so the unlock carries over. Builds for new kernels appear on <a href="<?= gu_h($m['releases']) ?>" target="_blank" rel="noopener">the releases page</a> within a day. The firmware is generated here from NVIDIA's own downloads and never redistributed.</p>
</div>
<?php
}
