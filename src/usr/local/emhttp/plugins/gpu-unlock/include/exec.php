<?php
/*
 * SPDX-License-Identifier: GPL-2.0-only
 * exec.php: POST endpoint for the page's buttons.
 *
 * CSRF is enforced for every POST by Unraid's local_prepend.php (csrf_token)
 * before this file runs. The only input used is the action name, looked up
 * in a fixed table; the control tool gets constant arguments. JSON out.
 */
declare(strict_types=1);

require_once __DIR__ . '/status.php';

header('Content-Type: application/json');
header('Cache-Control: no-store');

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    http_response_code(405);
    echo json_encode(['ok' => false, 'error' => 'POST required'], JSON_UNESCAPED_SLASHES), "\n";
    exit;
}

$gu_actions = [
    'fetch' => [['fetch'], 180],
    'fetch-pending' => [['fetch', '--pending'], 180],
    'check' => [['check'], 300],
    'firmware' => [['firmware', '--background'], 20],
    'enable' => [['enable'], 10],
    'disable' => [['disable'], 10],
    'hook-install' => [['hook-install'], 30],
];
$gu_action = $_POST['action'] ?? '';
if (!is_string($gu_action) || !isset($gu_actions[$gu_action])) {
    http_response_code(400);
    echo json_encode(['ok' => false, 'error' => 'unknown action'], JSON_UNESCAPED_SLASHES), "\n";
    exit;
}
[$gu_args, $gu_timeout] = $gu_actions[$gu_action];
[$gu_rc, $gu_out] = gu_run($gu_args, $gu_timeout);
http_response_code($gu_rc === 0 ? 200 : 400);
echo json_encode(['ok' => $gu_rc === 0, 'rc' => $gu_rc, 'output' => $gu_out],
    JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE), "\n";
