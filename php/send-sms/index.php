<?php

// Send one transactional SMS (an appointment reminder), then look up its status.
//
//   php send-sms/index.php +14155550100 Riverside

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

/** A random (version 4) UUID, used as an idempotency key. */
function uuidV4(): string
{
    $b = random_bytes(16);
    $b[6] = chr((ord($b[6]) & 0x0f) | 0x40);
    $b[8] = chr((ord($b[8]) & 0x3f) | 0x80);
    return vsprintf('%s%s-%s-%s-%s-%s%s%s', str_split(bin2hex($b), 4));
}

const DEFAULT_MESSAGE = 'Reminder: your appointment at Riverside Clinic is tomorrow at 10:30. '
    . 'Call us if you need to reschedule.';

if ($argc < 3 || $argc > 4) {
    fwrite(STDERR, 'Usage: php send-sms/index.php <to> <sender-id> [message]' . PHP_EOL);
    exit(2);
}
$to = $argv[1];
$senderId = $argv[2];
$message = $argv[3] ?? DEFAULT_MESSAGE;
if (getenv('PACKETEXCHANGE_API_KEY') === false || getenv('PACKETEXCHANGE_API_KEY') === '') {
    fwrite(STDERR, 'Set PACKETEXCHANGE_API_KEY first (see .env.example).' . PHP_EOL);
    exit(2);
}

// Smart Routing picks a route when routeId is omitted. The idempotency key makes a
// retry safe: the same key never sends (or bills) the message twice.
$sent = api(
    'POST',
    '/comms/sms',
    ['to' => $to, 'from' => $senderId, 'message' => $message],
    ['X-Idempotency-Key: ' . uuidV4()],
)['data'];
echo "Message submitted: {$sent['messageId']}" . PHP_EOL;
echo "  status: {$sent['status']}" . PHP_EOL;
echo "  segments: {$sent['segments']}" . PHP_EOL;
echo "  cost: {$sent['cost']}" . PHP_EOL;

// The send response is the send-time outcome (accepted, sent or failed). Delivery is
// confirmed later by a carrier receipt, when the route returns one: see sms-status.
$status = api('GET', '/comms/sms/' . rawurlencode($sent['messageId']))['data'];
echo "Status lookup: {$status['status']}" . PHP_EOL;
echo '  dlrSupported: ' . (($status['dlrSupported'] ?? false) ? 'true' : 'false') . PHP_EOL;
