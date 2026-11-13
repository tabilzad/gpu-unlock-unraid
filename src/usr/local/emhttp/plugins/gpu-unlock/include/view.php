<?php
/*
 * SPDX-License-Identifier: GPL-2.0-only
 * view.php: the content of the GPU Unlock page as an HTML fragment. The page
 * script requests it after every action and while a firmware generation runs,
 * and swaps it in, so the page never needs a reload. Read-only: it runs
 * `gpu-unlock-ctl status --json` and renders the result; no request data is used.
 */
declare(strict_types=1);

require_once __DIR__ . '/render.php';

header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');

echo gu_render(gu_status());
