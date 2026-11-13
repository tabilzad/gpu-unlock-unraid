#!/usr/bin/env php
<?php
/* Test helper: call one of the page's endpoints the way php-fpm would.
 *   run-endpoint.php exec|view METHOD [key=value ...]
 * The key=value pairs become $_POST. The endpoint under ROOT is included;
 * its body goes to stdout and "http <code>" to stderr when it is done. */
declare(strict_types=1);

$root = (string) getenv('ROOT');
$which = $argv[1] ?? '';
if ($root === '' || !in_array($which, ['exec', 'view'], true)) {
    fwrite(STDERR, "usage: ROOT=... run-endpoint.php exec|view METHOD [key=value ...]\n");
    exit(2);
}
$_SERVER['REQUEST_METHOD'] = $argv[2] ?? 'GET';
$_POST = [];
foreach (array_slice($argv, 3) as $pair) {
    [$k, $v] = array_pad(explode('=', $pair, 2), 2, '');
    $_POST[$k] = $v;
}
register_shutdown_function(static function (): void {
    $code = http_response_code();
    fwrite(STDERR, 'http ' . (is_int($code) ? $code : 200) . "\n");
});
require $root . '/usr/local/emhttp/plugins/gpu-unlock/include/' . $which . '.php';
