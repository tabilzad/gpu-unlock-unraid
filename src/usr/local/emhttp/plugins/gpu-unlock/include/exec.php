<?php
/*
 * SPDX-License-Identifier: GPL-2.0-only
 * exec.php: POST endpoint for the page's buttons.
 *
 * CSRF is enforced for every POST by Unraid's local_prepend.php (csrf_token)
 * before this file runs. The action name is looked up in a fixed table; the
 * only free-form input, the targets list, must match the module's own syntax
 * (all, or full PCI addresses) before it reaches the control tool as one
 * escaped argument. JSON out.
 */
declare(strict_types=1);

require_once __DIR__ . '/status.php';

header('Content-Type: application/json');
header('Cache-Control: no-store');

function gu_fail(int $code, string $error): never
{
    http_response_code($code);
    echo json_encode(['ok' => false, 'error' => $error], JSON_UNESCAPED_SLASHES), "\n";
    exit;
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    gu_fail(405, 'POST required');
}

$gu_actions = [
    'fetch' => [['fetch'], 180],
    'fetch-pending' => [['fetch', '--pending'], 180],
    'check' => [['check'], 300],
    'firmware' => [['firmware', '--background'], 20],
    'enable' => [['enable'], 10],
    'disable' => [['disable'], 10],
    'hook-install' => [['hook-install'], 30],
    'targets-clear' => [['targets', 'clear'], 10],
];
$gu_action = $_POST['action'] ?? '';
if (!is_string($gu_action)) {
    gu_fail(400, 'unknown action');
}
if ($gu_action === 'targets') {
    $gu_list = $_POST['targets'] ?? '';
    $gu_re = '/^(all|[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7](,[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-7])*)$/';
    if (!is_string($gu_list) || strlen($gu_list) > 512 || !preg_match($gu_re, $gu_list)) {
        gu_fail(400, 'targets must be "all" or full PCI addresses separated by commas');
    }
    $gu_args = ['targets', 'set', $gu_list];
    $gu_timeout = 10;
} elseif (isset($gu_actions[$gu_action])) {
    [$gu_args, $gu_timeout] = $gu_actions[$gu_action];
} else {
    gu_fail(400, 'unknown action');
}
[$gu_rc, $gu_out] = gu_run($gu_args, $gu_timeout);
http_response_code($gu_rc === 0 ? 200 : 400);
echo json_encode(['ok' => $gu_rc === 0, 'rc' => $gu_rc, 'output' => $gu_out],
    JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE), "\n";
