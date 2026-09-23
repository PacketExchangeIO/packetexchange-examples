<?php

// Rank every marketplace route for one phone number by what it would really cost, then
// show which route Smart Routing would pick for each strategy.
//
//   php price-a-number/index.php +447700900123
//   php price-a-number/index.php 447700900123 sms

declare(strict_types=1);

/**
 * Sends one API request and returns the decoded JSON body. Any non-2xx response ends the program.
 *
 * @param list<string> $headers extra "Name: value" request headers
 */
function api(string $method, string $path, ?array $body = null, array $headers = []): array
{
    $baseUrl = rtrim(getenv('PACKETEXCHANGE_BASE_URL') ?: 'https://packetexchange.io/api/v1', '/');
    $responseHeaders = [];
    $ch = curl_init($baseUrl . $path);
    curl_setopt_array($ch, [
        CURLOPT_CUSTOMREQUEST => $method,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT => 30,
        CURLOPT_HTTPHEADER => array_merge([
            'Authorization: Bearer ' . getenv('PACKETEXCHANGE_API_KEY'),
            'Content-Type: application/json',
            'Accept: application/json',
        ], $headers),
        // Collect response headers so errors can show the request id.
        CURLOPT_HEADERFUNCTION => function ($ch, string $line) use (&$responseHeaders): int {
            $parts = explode(':', $line, 2);
            if (count($parts) === 2) {
                $responseHeaders[strtolower(trim($parts[0]))] = trim($parts[1]);
            }
            return strlen($line);
        },
    ]);
    if ($body !== null) {
        curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($body, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES));
    }
    $text = curl_exec($ch);
    if ($text === false) {
        fwrite(STDERR, 'Network error: ' . curl_error($ch) . PHP_EOL);
        exit(1);
    }
    $status = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
    if ($status < 200 || $status >= 300) {
        exitWithApiError($status, $text, $responseHeaders);
    }
    return json_decode($text, true, 512, JSON_THROW_ON_ERROR);
}

/** Prints the API error envelope (code, message, field details, request id) and exits with 1. */
function exitWithApiError(int $status, string $text, array $headers): never
{
    $parsed = json_decode($text, true);
    $error = is_array($parsed) && is_array($parsed['error'] ?? null) ? $parsed['error'] : null;
    if ($error !== null && isset($error['code'])) {
        fwrite(STDERR, "Error {$status} {$error['code']}: {$error['message']}" . PHP_EOL);
        foreach (is_array($error['details'] ?? null) ? $error['details'] : [] as $d) {
            fwrite(STDERR, "  - {$d['path']}: {$d['message']}" . PHP_EOL);
        }
    } else {
        // Not a JSON envelope, for example an HTML error page from a proxy.
        fwrite(STDERR, "Error {$status}: " . substr($text, 0, 200) . PHP_EOL);
    }
    if ($status === 429 && isset($headers['retry-after'])) {
        fwrite(STDERR, "Retry after: {$headers['retry-after']} seconds" . PHP_EOL);
    }
    if (isset($headers['x-request-id'])) {
        fwrite(STDERR, "Request id: {$headers['x-request-id']}" . PHP_EOL);
    }
    exit(1);
}

const STRATEGIES = ['cheapest', 'best_quality', 'balanced'];

$type = $argv[2] ?? 'voice';
if ($argc < 2 || $argc > 3 || !in_array($type, ['voice', 'sms'], true)) {
    fwrite(STDERR, 'Usage: php price-a-number/index.php <number> [voice|sms]' . PHP_EOL);
    exit(2);
}
$number = $argv[1];
if (getenv('PACKETEXCHANGE_API_KEY') === false || getenv('PACKETEXCHANGE_API_KEY') === '') {
    fwrite(STDERR, 'Set PACKETEXCHANGE_API_KEY first (see .env.example).' . PHP_EOL);
    exit(2);
}
$unit = $type === 'sms' ? 'msg' : 'min';

// Each route is priced for this exact number: the longest matching rate-sheet prefix,
// or the listing's flat price. ASR figures are stated by the seller, not measured.
$priced = api('GET', '/routes/price-number?' . http_build_query(['number' => $number, 'type' => $type]))['data'];
if ($priced['notice'] === 'sanctioned') {
    echo 'No routes: the destination is embargoed.' . PHP_EOL;
} else {
    echo "{$priced['total']} routes serve {$number} ({$type}), cheapest first:" . PHP_EOL;
    foreach (array_slice($priced['routes'], 0, 5) as $r) {
        $asr = $r['expectedAsr'] === null ? 'ASR n/a' : "ASR {$r['expectedAsr']}% (seller-stated)";
        echo "  {$r['rate']}/{$priced['unit']}  {$r['destination']}  prefix {$r['matchedPrefix']}  {$asr}  {$r['id']}"
            . PHP_EOL;
    }
}

// Resolve runs as your account, so it also sees private routes you have bought.
foreach (STRATEGIES as $strategy) {
    $query = http_build_query(['to' => $number, 'type' => $type, 'strategy' => $strategy]);
    $s = api('GET', "/routes/resolve?{$query}")['data']['selected'];
    echo ($s !== null
        ? "Strategy {$strategy}: {$s['price']}/{$unit} via {$s['id']} ({$s['destinationName']})"
        : "Strategy {$strategy}: no route") . PHP_EOL;
}
