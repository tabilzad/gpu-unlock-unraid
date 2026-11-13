#!/usr/bin/env php
<?php
/* include/ui.php and include/model.php: the presentation helpers and the view
 * model behind the settings page, checked without a control tool.
 *   ui-test.php
 * Prints one line per check in the format of tests/lib.sh; exits 1 on a failure. */
declare(strict_types=1);

require dirname(__DIR__, 2) . '/src/usr/local/emhttp/plugins/gpu-unlock/include/model.php';

$fails = 0;
$count = 0;
function check(string $msg, bool $ok): void
{
    global $fails, $count;
    $count++;
    if ($ok) {
        echo "  ok   $msg\n";
    } else {
        $fails++;
        fwrite(STDERR, "  FAIL $msg\n");
    }
}

// themes
check('theme: white-bannered is white', gu_theme('white-bannered') === 'white');
check('theme: grey is gray', gu_theme(' Grey ') === 'gray');
check('theme: unknown, empty and non-string fall back to black', gu_theme('neon') === 'black' && gu_theme('') === 'black' && gu_theme(null) === 'black');

// badges, icons, buttons
check('badge: label escaped, tone kept', gu_badge('<b>', 'ok') === '<span class="gu-badge" data-tone="ok">&lt;b&gt;</span>');
check('badge: an unknown tone is neutral', gu_badge('x', 'purple" onclick="x') === '<span class="gu-badge" data-tone="neutral">x</span>');
check('badge: the title is escaped', str_contains(gu_badge('x', 'warn', '"quoted"'), 'title="&quot;quoted&quot;"'));
check('icon: a known name is an svg', str_starts_with(gu_icon('unlock'), '<svg class="gu-icon"'));
check('icon: an unknown name is empty', gu_icon('<script>') === '' && gu_icon('nope') === '');
$b = gu_button('fetch"x', '<Fetch>', 'download', 'primary sm bogus', ['kernel' => '6.18"', 'BAD KEY' => 'x'], 'a "title"');
check('button: action, label, data and title are escaped', str_contains($b, 'data-action="fetch&quot;x"') && str_contains($b, '<span>&lt;Fetch&gt;</span>')
    && str_contains($b, 'data-kernel="6.18&quot;"') && str_contains($b, 'title="a &quot;title&quot;"'));
check('button: known variants only, bad data keys dropped', str_contains($b, 'class="gu-btn gu-btn-primary gu-btn-sm"') && !str_contains($b, 'BAD') && !str_contains($b, 'bogus'));

// small formatters
check('count: singular and plural', gu_count(1, 'card', 'cards') === '1 card' && gu_count(0, 'card', 'cards') === '0 cards');
check('kib: MB, GB, unknown', gu_kib(153600) === '150 MB' && gu_kib(2097152) === '2.0 GB' && gu_kib(null) === 'unknown' && gu_kib(-1) === 'unknown');

// the model
$base = [
    'plugin_version' => '2026.11.06.1', 'module_version' => '2.0.0', 'nv' => '610.43.03',
    'kernel' => '6.18.58-Unraid', 'pending_kernel' => '', 'module_present' => true, 'pending_module_present' => false,
    'firmware_state' => 'present', 'firmware_present' => true, 'firmware_files' => 16, 'firmware_missing' => [],
    'hook_installed' => true, 'hook_conflict' => '', 'disabled' => false, 'safe_mode' => false,
    'targets' => '0000:01:00.0', 'targets_source' => 'file', 'module_loaded' => false, 'nvidia_loaded' => true,
    'hook_status' => '', 'verdicts' => [['address' => '0000:01:00.0', 'state' => 'pending', 'reason' => 'no result in the kernel log', 'power_off' => false]],
    'power_off_required' => false, 'flash_free_kb' => 4000000,
    'cards' => [['address' => '0000:01:00.0', 'device' => '0x2204', 'driver' => 'nvidia', 'supported' => true, 'chip' => 'GA102', 'experimental' => false, 'name' => 'GeForce RTX 3090']],
];
$m = gu_model($base);
check('model: everything in place is ready', $m['ready'] === true && $m['headline']['tone'] === 'info');
check('model: five steps, the power cycle is the one to act on', count($m['steps']) === 5 && $m['steps'][4]['current'] === true && $m['steps'][4]['tone'] === 'info');
check('model: before the first boot a chosen card waits for it', $m['rows'][0]['result']['label'] === 'at the next boot' && $m['rows'][0]['chosen'] === true);

$m = gu_model(['pending_kernel' => '6.18.70-Unraid'] + $base);
check('model: a staged kernel without a module blocks the next boot', $m['ready'] === false && str_contains($m['headline']['text'], '6.18.70-Unraid')
    && $m['steps'][0]['actions'][0][0] === 'fetch-pending' && $m['steps'][0]['current'] === true);
$m = gu_model(['pending_kernel' => '6.18.70-Unraid', 'pending_module_present' => true, 'module_present' => false] + $base);
check('model: the staged kernel counts, not the running one', $m['ready'] === true && $m['steps'][0]['tone'] === 'ok');

$m = gu_model(['firmware_state' => 'incomplete', 'firmware_present' => false, 'firmware_missing' => ['a.bin', 'b.bin']] + $base);
check('model: incomplete firmware is usable with a warning', $m['ready'] === true && $m['tiles'][1]['tone'] === 'warn' && $m['steps'][1]['tone'] === 'warn'
    && str_contains($m['steps'][1]['text'], '2 files are missing'));
$m = gu_model(['firmware_state' => 'damaged', 'firmware_present' => false] + $base);
check('model: damaged firmware is not', $m['ready'] === false && $m['steps'][1]['tone'] === 'bad');

$m = gu_model(['targets' => '', 'targets_source' => 'none', 'verdicts' => []] + $base);
check('model: no card chosen', $m['ready'] === false && $m['steps'][2]['current'] === true && $m['tiles'][2]['value'] === '0 of 1' && $m['rows'][0]['result'] === null);
$m = gu_model(['targets' => '0000:01:00.0,0000:09:00.0'] + $base);
check('model: a saved address that is no card any more is called out', count(array_filter($m['notices'], static fn (array $n): bool => str_contains($n['text'], '0000:09:00.0'))) === 1);
$m = gu_model(['disabled' => true] + $base);
check('model: switched off', $m['ready'] === false && $m['tiles'][1]['value'] === 'Switched off' && $m['steps'][3]['actions'][0][0] === 'enable');

$booted = ['hook_status' => 'loaded: gpu_unlock for 6.18.58-Unraid', 'module_loaded' => true,
    'verdicts' => [['address' => '0000:01:00.0', 'state' => 'unlocked', 'reason' => '', 'power_off' => false]]] + $base;
$m = gu_model($booted);
check('model: unlocked this boot', $m['headline']['tone'] === 'ok' && $m['headline']['text'] === '1 card unlocked this boot.' && $m['steps'][4]['tone'] === 'ok'
    && $m['rows'][0]['result']['label'] === 'unlocked' && array_search(true, array_column($m['steps'], 'current'), true) === false);
$m = gu_model(['power_off_required' => true, 'verdicts' => [['address' => '0000:01:00.0', 'state' => 'failed', 'reason' => 'WPR2 enabled; power off first', 'power_off' => true]]] + $booted);
check('model: power off required leads', $m['headline']['tone'] === 'bad' && str_starts_with($m['headline']['text'], 'Power off required') && $m['notices'] === [] && $m['steps'][4]['tone'] === 'bad'
    && $m['rows'][0]['result']['power_off'] === true && $m['tiles'][0]['value'] === 'Power off');

$m = gu_model(['firmware_job' => true, 'firmware_phase' => 'download', 'firmware_log' => ['a', 'b'], 'firmware_state' => 'missing', 'firmware_present' => false] + $base);
check('model: a running generation shows its phases', $m['job'] === true && $m['steps'][1]['tone'] === 'info'
    && array_column($m['steps'][1]['phases'], 'state') === ['done', 'active', 'todo', 'todo'] && $m['steps'][1]['log'] === ['a', 'b']);
$m = gu_model(['firmware_job' => false, 'firmware_job_rc' => '1', 'firmware_phase' => 'download', 'firmware_state' => 'missing', 'firmware_present' => false] + $base);
check('model: a failed generation marks the phase it stopped in', array_column($m['steps'][1]['phases'], 'state') === ['done', 'failed', 'todo', 'todo']
    && $m['steps'][1]['tone'] === 'bad' && $m['steps'][1]['actions'][0][0] === 'firmware');

$m = gu_model(['cards' => 'nonsense', 'verdicts' => null, 'modules' => 7, 'kernel_log' => 'x', 'flash_free_kb' => 'big'] + $base);
check('model: malformed lists do not break it', $m['rows'] === [] && $m['boot']['log'] === [] && $m['flash']['free'] === 'unknown');

echo "$count checks, $fails failed\n";
exit($fails === 0 ? 0 : 1);
