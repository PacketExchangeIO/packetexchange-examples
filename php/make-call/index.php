<?php

// Place one outbound call and read its outcome and cost, then find its ledger entry.
// POST /comms/calls returns when the call has ended, so the client waits for it.
//
//   php make-call/index.php +14155550100 +14155550199 60

declare(strict_types=1);

/**
 * Sends one API request and returns the decoded JSON body. Any non-2xx response ends the program.
 *
 * @param list<string> $headers extra "Name: value" request headers
 */
function api(string $method, string $path, ?array $body = null, array $headers = [], int $timeoutSeconds = 30): array
{
    $baseUrl = rtrim(getenv('PACKETEXCHANGE_BASE_URL') ?: 'https://packetexchange.io/api/v1', '/');
    $responseHeaders = [];
    $ch = curl_init($baseUrl . $path);
    curl_setopt_array($ch, [
        CURLOPT_CUSTOMREQUEST => $method,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_TIMEOUT => $timeoutSeconds,
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

/** A random (version 4) UUID, used as an idempotency key. */
function uuidV4(): string
{
    $b = random_bytes(16);
    $b[6] = chr((ord($b[6]) & 0x0f) | 0x40);
    $b[8] = chr((ord($b[8]) & 0x3f) | 0x80);
    return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($b), 4));
}

if ($argc < 3 || $argc > 4 || ($argc === 4 && !ctype_digit($argv[3]))) {
    fwrite(STDERR, 'Usage: php make-call/index.php <to> <caller-id> [max-duration-seconds]' . PHP_EOL);
    exit(2);
}
$to = $argv[1];
$callerId = $argv[2];
$maxDuration = (int) ($argv[3] ?? 60);
if (getenv('PACKETEXCHANGE_API_KEY') === false || getenv('PACKETEXCHANGE_API_KEY') === '') {
    fwrite(STDERR, 'Set PACKETEXCHANGE_API_KEY first (see .env.example).' . PHP_EOL);
    exit(2);
}

// The request stays open until the call is answered and hung up, not answered, or
// reaches maxDuration, so the client timeout must be longer than maxDuration.
$call = api(
    'POST',
    '/comms/calls',
    ['to' => $to, 'from' => $callerId, 'maxDuration' => $maxDuration],
    ['X-Idempotency-Key: ' . uuidV4()],
    $maxDuration + 30,
)['data'];
echo "Call finished: {$call['callId']}" . PHP_EOL;
echo "  status: {$call['status']}" . PHP_EOL;
echo "  durationSeconds: {$call['durationSeconds']}" . PHP_EOL;
echo "  billableSeconds: {$call['billableSeconds']}" . PHP_EOL;
echo "  cost: {$call['cost']}" . PHP_EOL;
echo '  hangupCause: ' . ($call['hangupCause'] ?? 'none') . PHP_EOL;

// Call history is the account ledger, newest first; the entry references the call id.
$entries = api('GET', '/comms/calls?limit=25')['data'];
$entry = null;
foreach ($entries as $e) {
    if (($e['relatedEntityId'] ?? null) === $call['callId'] || ($e['callId'] ?? null) === $call['callId']) {
        $entry = $e;
        break;
    }
}
echo ($entry !== null
    ? "Ledger entry: {$entry['amount']} (balance after {$entry['balanceAfter']})"
    : 'Ledger entry: not in the latest 25 entries') . PHP_EOL;
