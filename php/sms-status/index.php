<?php

// Read what happened to a message you sent: every step from queued to delivered or
// failed, with timestamps. "delivered" only ever comes from a carrier receipt.
//
//   php sms-status/index.php <messageId>

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

if ($argc !== 2) {
    fwrite(STDERR, 'Usage: php sms-status/index.php <message-id>' . PHP_EOL);
    exit(2);
}
$messageId = $argv[1];
if (getenv('PACKETEXCHANGE_API_KEY') === false || getenv('PACKETEXCHANGE_API_KEY') === '') {
    fwrite(STDERR, 'Set PACKETEXCHANGE_API_KEY first (see .env.example).' . PHP_EOL);
    exit(2);
}

$sms = api('GET', '/comms/sms/' . rawurlencode($messageId))['data'];

// An id that is not on your account answers 200 with status not_found.
if ($sms['status'] === 'not_found') {
    fwrite(STDERR, "No message {$messageId} on this account." . PHP_EOL);
    exit(1);
}
echo "Message {$sms['messageId']}: {$sms['status']}" . PHP_EOL;
foreach ($sms['timeline'] ?? [] as $step) {
    $extra = array_filter([$step['source'], $step['carrierStatus'] ?? null, $step['errorCode'] ?? null], fn ($v) => $v !== null && $v !== '');
    echo "  - {$step['status']} at {$step['at']} (" . implode(', ', $extra) . ')' . PHP_EOL;
}
if (!empty($sms['errorCode'])) {
    echo "  errorCode: {$sms['errorCode']}" . PHP_EOL;
}
// A route that returns no receipts leaves the message at "sent" for good.
echo '  awaitingReceipt: ' . (($sms['awaitingReceipt'] ?? false) ? 'true' : 'false') . PHP_EOL;
$receipts = $sms['routeReturnsReceipts'] ?? null;
echo '  routeReturnsReceipts: ' . ($receipts === null ? 'unknown' : ($receipts ? 'true' : 'false')) . PHP_EOL;
