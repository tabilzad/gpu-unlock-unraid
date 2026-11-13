<?php
/* Router of the page preview (tests/preview.sh): PHP's built-in web server
 * standing in for Unraid's WebGUI. It serves the settings page inside a bare
 * shell that imitates what the WebGUI gives a page (the theme's background
 * and text color, jQuery, a csrf_token variable, Unraid's global button and
 * table rules, which the page's stylesheet has to outrank), plus the
 * plugin's own endpoints and assets from the fake root in ROOT.
 *
 *   /                 the page; ?theme=black|white|azure|gray
 *   /plugins/gpu-unlock/include/exec.php, view.php, styles/*, javascript/*
 *
 * Development only: no authentication, no CSRF check. Never run it on a server. */
declare(strict_types=1);

$root = (string) getenv('ROOT');
$emhttp = $root . '/usr/local/emhttp';
$uri = (string) parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH);

if (preg_match('#^/plugins/gpu-unlock/include/(exec|view)\.php$#', $uri, $m)) {
    require "$emhttp/plugins/gpu-unlock/include/$m[1].php";
    return true;
}
if (preg_match('#^/plugins/gpu-unlock/(styles|javascript)/([A-Za-z0-9._-]+\.(css|js))$#', $uri, $m)) {
    $file = "$emhttp/plugins/gpu-unlock/$m[1]/$m[2]";
    if (!is_file($file)) {
        http_response_code(404);
        return true;
    }
    header('Content-Type: ' . ($m[3] === 'css' ? 'text/css' : 'application/javascript'));
    header('Cache-Control: no-store');
    readfile($file);
    return true;
}
if ($uri !== '/') {
    http_response_code(404);
    echo "not found\n";
    return true;
}

$themes = [
    'black' => ['#1c1b1b', '#f2f2f2'],
    'white' => ['#f2f2f2', '#1c1b1b'],
    'azure' => ['#e4e2e4', '#606e7f'],
    'gray' => ['#1b1d1b', '#a3a8a3'],
];
$theme = isset($themes[$_GET['theme'] ?? '']) ? (string) $_GET['theme'] : 'black';
[$bg, $fg] = $themes[$theme];
$display = ['theme' => $theme];
$_SERVER['DOCUMENT_ROOT'] = $emhttp;
$page = (string) file_get_contents("$emhttp/plugins/gpu-unlock/GpuUnlock.page");
$body = (string) preg_replace('/\A.*?^---\r?\n/ms', '', $page, 1);
header('Content-Type: text/html; charset=utf-8');
header('Cache-Control: no-store');
?>
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>GPU Unlock: page preview</title>
<style>
html { font-size: 62.5%; }
body { margin: 0; padding: 0 20px 40px; background: <?= htmlspecialchars($bg) ?>; color: <?= htmlspecialchars($fg) ?>; font-family: clear-sans, "Segoe UI", Arial, sans-serif; font-size: 1.3rem; }
.preview-bar { display: flex; gap: 14px; align-items: center; padding: 10px 0; margin-bottom: 14px; border-bottom: 1px solid rgba(128, 128, 128, 0.4); font-size: 1.2rem; }
.preview-bar a { color: inherit; }
.title { font-size: 1.8rem; font-weight: bold; text-transform: uppercase; letter-spacing: 1.8px; margin: 10px 0 20px; }
/* What Unraid applies to every button and table; the page has to outrank it. */
button, input[type=button] { font-family: inherit; font-size: 1.1rem; font-weight: bold; letter-spacing: 1.8px; text-transform: uppercase; min-width: 86px; margin: 10px 12px 10px 0; padding: 9px 10px; border: 0; border-radius: 4px; color: #ff8c2f; cursor: pointer; background: linear-gradient(90deg, #e22828 0, #ff8c2f) 0 0 no-repeat, linear-gradient(90deg, #e22828 0, #ff8c2f) 0 100% no-repeat, linear-gradient(0deg, #e22828 0, #e22828) 0 100% no-repeat, linear-gradient(0deg, #ff8c2f 0, #ff8c2f) 100% 100% no-repeat; background-size: 100% 2px, 100% 2px, 2px 100%, 2px 100%; }
table { border-collapse: collapse; border-spacing: 0; border-style: hidden; width: 100%; margin: 0 0 20px; }
table tbody td { height: 3rem; line-height: 3rem; }
</style>
<script src="https://code.jquery.com/jquery-3.7.1.min.js" integrity="sha384-1H217gwSVyLSIfaLxHbE7dRb3v4mYCKbpQvzx0cegeju1MVsGrX5xXxAvs/HgeFs" crossorigin="anonymous"></script>
<script>var csrf_token = 'preview';</script>
</head>
<body>
<div class="preview-bar"><strong>Page preview, not Unraid</strong>
<?php foreach (array_keys($themes) as $t): ?>
<a href="/?theme=<?= htmlspecialchars($t) ?>"><?= htmlspecialchars($t) ?></a>
<?php endforeach; ?>
</div>
<div class="title">GPU Unlock</div>
<?php
// eval() of the checked-in page source is what DefaultPageLayout does on the
// box; no request data reaches it (the theme is one of four fixed names).
eval('?>' . $body);
?>
</body>
</html>
<?php
return true;
