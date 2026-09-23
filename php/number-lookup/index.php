<?php

// Look up a phone number before you message or call it: whether it is a valid E.164
// number, its country, line type and network, risk flags, and the cheapest live price.
//
//   php number-lookup/index.php +447700900123

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

/** One price line: the cheapest live route, or "no route" when none serves the number. */
function priceLine(string $label, ?array $price): string
{
    if ($price === null) {
        return "  {$label}: no route";
    }
    return "  {$label}: {$price['rate']}/{$price['unit']} via {$price['routeId']} ({$price['routesServing']} routes serve it)";
}

if ($argc !== 2) {
    fwrite(STDERR, 'Usage: php number-lookup/index.php <number>' . PHP_EOL);
    exit(2);
}
$number = $argv[1];
if (getenv('PACKETEXCHANGE_API_KEY') === false || getenv('PACKETEXCHANGE_API_KEY') === '') {
    fwrite(STDERR, 'Set PACKETEXCHANGE_API_KEY first (see .env.example).' . PHP_EOL);
    exit(2);
}

// Encode the number for use in the URL path, leading "+" included.
$data = api('GET', '/lookup/' . rawurlencode($number))['data'];

// A malformed number is a normal answer (valid: false), not an HTTP error.
if (!$data['valid']) {
    echo "Not a valid number: {$data['reason']}" . PHP_EOL;
    exit(0);
}
$country = $data['country'];
$risk = $data['risk'];
echo "{$data['e164']} ({$data['internationalFormat']})" . PHP_EOL;
echo '  country: ' . ($country === null ? 'unknown' : "{$country['name']} (" . ($country['iso'] ?? 'shared dial code') . ')') . PHP_EOL;
echo "  numberType: {$data['numberType']}" . PHP_EOL;
// From number-range data: a ported number still shows the network its range belongs to.
echo '  network: ' . ($data['network']['operator'] ?? 'unknown') . PHP_EOL;
echo '  risk: blocked ' . ($risk['blocked'] ? 'true' : 'false') . ', highRisk ' . ($risk['highRisk'] ? 'true' : 'false') . PHP_EOL;
foreach ($risk['reasons'] as $reason) {
    echo "    - {$reason}" . PHP_EOL;
}
echo priceLine('voice', $data['pricing']['voice']) . PHP_EOL;
echo priceLine('sms', $data['pricing']['sms']) . PHP_EOL;
