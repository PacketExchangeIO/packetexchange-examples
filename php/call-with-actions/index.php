<?php

// Call a customer to confirm an appointment: the answered call speaks a message, asks
// for one key press, and the program follows the call until it ends.
//
//   php call-with-actions/index.php +14155550100 +14155550199

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

// What the answered call does, in order. The call hangs up after the last action.
const ACTIONS = [
    ['say' => 'Hello, this is Riverside Clinic calling about your appointment tomorrow at 10:30.'],
    ['gather' => ['digits' => 1, 'timeout' => 5, 'say' => 'Press 1 to confirm, or 2 if you need to reschedule.']],
    ['say' => 'Thank you. Goodbye.'],
];
const FINAL_STATUSES = ['completed', 'no_answer', 'busy', 'failed'];
const POLL_EVERY_SECONDS = 2;
const GIVE_UP_AFTER_SECONDS = 300;

if ($argc !== 3) {
    fwrite(STDERR, 'Usage: php call-with-actions/index.php <to> <caller-id>' . PHP_EOL);
    exit(2);
}
[, $to, $callerId] = $argv;
if (getenv('PACKETEXCHANGE_API_KEY') === false || getenv('PACKETEXCHANGE_API_KEY') === '') {
    fwrite(STDERR, 'Set PACKETEXCHANGE_API_KEY first (see .env.example).' . PHP_EOL);
    exit(2);
}

// async: true answers as soon as the number is being dialled (HTTP 202, status
// ringing) instead of holding the request open until the call ends.
$placed = api(
    'POST',
    '/comms/calls',
    ['to' => $to, 'from' => $callerId, 'maxDuration' => 120, 'async' => true, 'language' => 'en', 'actions' => ACTIONS],
    ['X-Idempotency-Key: ' . uuidV4()],
)['data'];
echo "Call placed: {$placed['callId']} (status {$placed['status']})" . PHP_EOL;

// Poll the call until it ends. In production, the call.answered, call.gathered and
// call.completed webhooks tell you the same without polling.
$deadline = time() + GIVE_UP_AFTER_SECONDS;
$lastStatus = $placed['status'];
while (true) {
    $call = api('GET', '/comms/calls/' . rawurlencode($placed['callId']))['data'];
    if ($call['status'] !== $lastStatus) {
        echo "  status: {$call['status']}" . PHP_EOL;
        $lastStatus = $call['status'];
    }
    if (in_array($call['status'], FINAL_STATUSES, true)) {
        // Gathered digits are filled in when the call ends.
        $pressed = null;
        foreach ($call['gathered'] ?? [] as $entry) {
            if ($entry['index'] === 0) {
                $pressed = $entry['digits'];
            }
        }
        echo "Call ended: {$call['status']}" . PHP_EOL;
        echo '  durationSeconds: ' . ($call['durationSeconds'] ?? 0) . PHP_EOL;
        echo '  cost: ' . ($call['cost'] ?? 'none') . PHP_EOL;
        echo '  hangupReason: ' . ($call['hangupReason'] ?? 'none') . PHP_EOL;
        echo '  keyPressed: ' . ($pressed ?? 'none') . PHP_EOL;
        break;
    }
    if (time() + POLL_EVERY_SECONDS > $deadline) {
        echo "Still running after 5 minutes; check GET /comms/calls/{$placed['callId']} later." . PHP_EOL;
        break;
    }
    sleep(POLL_EVERY_SECONDS);
}
