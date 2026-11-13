<?php
/*
 * SPDX-License-Identifier: GPL-2.0-only
 * status.php: helpers for the GPU Unlock page and its endpoints. Everything the
 * page shows comes from `gpu-unlock-ctl status --json`; every value printed
 * into HTML goes through gu_h().
 */
declare(strict_types=1);

/** The control tool. ROOT is empty on a real server; the test suite sets it. */
function gu_ctl(): string
{
    return (string) getenv('ROOT') . '/usr/local/sbin/gpu-unlock-ctl';
}

/** HTML-escape for output into the page. */
function gu_h(mixed $value): string
{
    return htmlspecialchars((string) $value, ENT_QUOTES | ENT_SUBSTITUTE | ENT_HTML5, 'UTF-8');
}

/**
 * Run the control tool with fixed arguments and a timeout; returns [rc, output].
 * Arguments are constants chosen by the caller, or request data the caller
 * validated first; each one is passed through escapeshellarg().
 *
 * @param list<string> $args
 * @return array{0:int,1:string}
 */
function gu_run(array $args, int $timeout = 20): array
{
    $cmd = 'timeout ' . $timeout . ' ' . escapeshellarg(gu_ctl());
    foreach ($args as $a) {
        $cmd .= ' ' . escapeshellarg($a);
    }
    $out = [];
    $rc = 1;
    exec($cmd . ' 2>&1', $out, $rc);
    return [$rc, implode("\n", array_map(static fn ($l): string => (string) $l, $out))];
}

/** `gpu-unlock-ctl status --json` decoded, or [] when unavailable. */
function gu_status(): array
{
    [$rc, $out] = gu_run(['status', '--json']);
    if ($rc !== 0) {
        return [];
    }
    try {
        $data = json_decode($out, true, 16, JSON_THROW_ON_ERROR | JSON_INVALID_UTF8_SUBSTITUTE);
    } catch (JsonException) {
        return [];
    }
    return is_array($data) ? $data : [];
}
