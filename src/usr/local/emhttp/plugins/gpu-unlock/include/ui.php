<?php
/*
 * SPDX-License-Identifier: GPL-2.0-only
 * ui.php: presentation helpers for the GPU Unlock page. Pure functions, no I/O
 * except gu_asset_version(): the theme name Unraid reports, badges, buttons and
 * inline SVG icons. Everything that reaches HTML goes through gu_h().
 *
 * The visual system (header, notices, summary cards, sections, badges) is the
 * one of tabilzad/claude-code-unraid, by the same author.
 */
declare(strict_types=1);

require_once __DIR__ . '/status.php';

/** The four Unraid themes the stylesheet carries fallbacks for. */
const GU_THEMES = ['black', 'white', 'azure', 'gray'];

/** Tones the stylesheet knows for badges, cards, notices and steps. */
const GU_TONES = ['ok', 'warn', 'bad', 'info', 'neutral'];

/**
 * Normalise Unraid's display theme ("white-bannered", "azure", "grey", ...) to
 * one of GU_THEMES. Unknown or empty values fall back to black, the default
 * theme and the one the stylesheet's base tokens are written for.
 */
function gu_theme(mixed $raw): string
{
    $name = strtolower(trim(is_string($raw) ? $raw : ''));
    $name = strtok($name, '-') ?: '';
    if ($name === 'grey') {
        $name = 'gray';
    }
    return in_array($name, GU_THEMES, true) ? $name : 'black';
}

/** A known tone, or neutral. */
function gu_tone(mixed $tone): string
{
    return is_string($tone) && in_array($tone, GU_TONES, true) ? $tone : 'neutral';
}

/** A pill badge. Unknown tones render as neutral. */
function gu_badge(mixed $label, string $tone = 'neutral', string $title = ''): string
{
    return '<span class="gu-badge" data-tone="' . gu_tone($tone) . '"'
        . ($title === '' ? '' : ' title="' . gu_h($title) . '"') . '>' . gu_h($label) . '</span>';
}

/**
 * Inline SVG icons (stroke based, 24-unit viewBox). The markup is constant and
 * carries no user data. Unknown names give an empty string.
 */
function gu_icon(string $name): string
{
    static $paths = [
        'unlock' => '<rect x="4.5" y="10.5" width="15" height="10" rx="2"/><path d="M8 10.5V7a4 4 0 0 1 7.7-1.5"/><path d="M12 14.5v2.5"/>',
        'check' => '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
        'warning' => '<path d="M12 4 2.5 20h19Z"/><path d="M12 10v4M12 17h.01"/>',
        'info' => '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8h.01"/>',
        'refresh' => '<path d="M21 12a9 9 0 1 1-3-6.7"/><path d="M21 4.5v5h-5"/>',
        'chip' => '<rect x="7" y="7" width="10" height="10" rx="1.5"/><path d="M10 3.5V7M14 3.5V7M10 17v3.5M14 17v3.5M3.5 10H7M3.5 14H7M17 10h3.5M17 14h3.5"/>',
        'power' => '<path d="M12 3.5v8"/><path d="M6.6 6.6a8 8 0 1 0 10.8 0"/>',
        'drive' => '<rect x="3.5" y="13" width="17" height="7" rx="2"/><path d="M6 13 8 4.5h8L18 13"/><path d="M7.5 16.5h.01M11 16.5h.01"/>',
        'download' => '<path d="M12 4v11"/><path d="m7.5 11 4.5 4.5 4.5-4.5"/><path d="M5 19.5h14"/>',
        'copy' => '<rect x="8.5" y="8.5" width="11" height="12" rx="2"/><path d="M15.5 8.5V6a2 2 0 0 0-2-2h-7a2 2 0 0 0-2 2v8.5a2 2 0 0 0 2 2h2"/>',
        'list' => '<path d="M10 6h10M10 12h10M10 18h10"/><path d="m3.5 6 1.2 1.2L7 4.9M3.5 12l1.2 1.2L7 10.9M3.5 18l1.2 1.2L7 16.9"/>',
        'save' => '<path d="M5 4h11l3 3v13H5Z"/><path d="M8 4v5h7V4M8 20v-6h8v6"/>',
        'pause' => '<path d="M9 5v14M15 5v14"/>',
        'play' => '<path d="m8 5 11 7-11 7Z"/>',
        'log' => '<path d="M6 3h8l4 4v14H6Z"/><path d="M14 3v5h4M9 12h6M9 16h6"/>',
        'pulse' => '<path d="M3 12h4l2.5-6 4 12 2.5-6h5"/>',
        'cog' => '<circle cx="12" cy="12" r="3"/><path d="M12 3.5v3M12 17.5v3M3.5 12h3M17.5 12h3M6 6l2.1 2.1M15.9 15.9 18 18M6 18l2.1-2.1M15.9 8.1 18 6"/>',
    ];
    if (!isset($paths[$name])) {
        return '';
    }
    return '<svg class="gu-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">' . $paths[$name] . '</svg>';
}

/**
 * A button that posts an action through the page script. $variant is primary,
 * warn, sm or a combination ("primary sm"); $data adds data-* attributes.
 *
 * @param array<string,string> $data
 */
function gu_button(string $action, string $label, string $icon = '', string $variant = '', array $data = [], string $title = ''): string
{
    $class = 'gu-btn';
    foreach (['primary', 'warn', 'sm'] as $v) {
        if (str_contains(" $variant ", " $v ")) {
            $class .= ' gu-btn-' . $v;
        }
    }
    $attrs = ' data-action="' . gu_h($action) . '"';
    foreach ($data as $k => $v) {
        if (preg_match('/^[a-z][a-z0-9-]*$/', (string) $k)) {
            $attrs .= ' data-' . $k . '="' . gu_h($v) . '"';
        }
    }
    if ($title !== '') {
        $attrs .= ' title="' . gu_h($title) . '"';
    }
    return '<button type="button" class="' . $class . '"' . $attrs . '>' . gu_icon($icon) . '<span>' . gu_h($label) . '</span></button>';
}

/** "1 card" / "2 cards". */
function gu_count(int $n, string $one, string $many): string
{
    return $n . ' ' . ($n === 1 ? $one : $many);
}

/** A size in KiB as MB or GB, for the free space on the flash drive. */
function gu_kib(mixed $kib): string
{
    if (!is_int($kib) || $kib < 0) {
        return 'unknown';
    }
    if ($kib >= 1048576) {
        return number_format($kib / 1048576, 1) . ' GB';
    }
    return (string) (int) round($kib / 1024) . ' MB';
}

/** Cache-busting token for a packaged asset: its mtime, or "dev" when missing. */
function gu_asset_version(string $path): string
{
    $t = @filemtime($path);
    return $t === false ? 'dev' : (string) $t;
}
