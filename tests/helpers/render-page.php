#!/usr/bin/env php
<?php
/* Test helper: render GpuUnlock.page the way Unraid's DefaultPageLayout does.
 *   render-page.php [THEME]
 * The page body after the "---" header is evaluated with $display['theme'] set
 * to THEME and DOCUMENT_ROOT pointing at the fake root's emhttp directory, so
 * the page, its includes and the control tool are the copies under ROOT.
 * Prints the HTML. */
declare(strict_types=1);

$root = (string) getenv('ROOT');
if ($root === '') {
    fwrite(STDERR, "render-page: ROOT is not set\n");
    exit(2);
}
$display = ['theme' => $argv[1] ?? 'black'];
$_SERVER['DOCUMENT_ROOT'] = $root . '/usr/local/emhttp';
$page = file_get_contents($_SERVER['DOCUMENT_ROOT'] . '/plugins/gpu-unlock/GpuUnlock.page');
if ($page === false) {
    fwrite(STDERR, "render-page: cannot read GpuUnlock.page\n");
    exit(2);
}
$body = preg_replace('/\A.*?^---\r?\n/ms', '', $page, 1);
// eval() of the checked-in page source is the point of this helper: it is
// what DefaultPageLayout does on the box. No request or user data is involved.
eval('?>' . $body);
