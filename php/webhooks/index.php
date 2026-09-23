<?php

// A minimal webhook receiver that verifies PacketExchange signatures before trusting a delivery.
// Run it with PHP's built-in server:
//
//   PACKETEXCHANGE_WEBHOOK_SECRET=... php -S localhost:3000 webhooks/index.php
//
// Current scheme:  X-PX-Timestamp: <unix seconds>
//                  X-PX-Signature: v1=<hex HMAC-SHA256(secret, "<timestamp>.<raw body>")>
// Legacy scheme:   X-Webhook-Signature: sha256=<hex HMAC-SHA256(secret, <raw body>)>

declare(strict_types=1);

// Deliveries older (or newer) than this are refused, so a captured request cannot be replayed later.
const TOLERANCE_SECONDS = 300;

/**
 * Checks the signature over the exact bytes received, before the body is parsed.
 *
 * @return array{0: bool, 1: string} [true, scheme] when authentic, or [false, reason]
 */
function verify(string $secret, string $rawBody): array
{
    $signature = $_SERVER['HTTP_X_PX_SIGNATURE'] ?? null;
    if ($signature !== null) {
        $timestamp = $_SERVER['HTTP_X_PX_TIMESTAMP'] ?? '';
        if (!ctype_digit($timestamp)) {
            return [false, 'missing or malformed X-PX-Timestamp'];
        }
        if (abs(time() - (int) $timestamp) > TOLERANCE_SECONDS) {
            return [false, 'timestamp outside the 5-minute window'];
        }
        $expected = 'v1=' . hash_hmac('sha256', $timestamp . '.' . $rawBody, $secret);
        // hash_equals takes the same time wherever the strings differ.
        return hash_equals($expected, $signature) ? [true, 'v1'] : [false, 'invalid v1 signature'];
    }

    // Fallback for senders that only attach the legacy header. It proves who sent the body
    // but not when, so it cannot stop replays; prefer v1 whenever it is present.
    $legacy = $_SERVER['HTTP_X_WEBHOOK_SIGNATURE'] ?? null;
    if ($legacy !== null) {
        $expected = 'sha256=' . hash_hmac('sha256', $rawBody, $secret);
        return hash_equals($expected, $legacy) ? [true, 'legacy'] : [false, 'invalid legacy signature'];
    }
    return [false, 'no signature header'];
}

/** Writes a log line to the server console (stdout or stderr). */
function logLine(string $line, bool $isError = false): void
{
    file_put_contents($isError ? 'php://stderr' : 'php://stdout', $line . PHP_EOL);
}

$secret = getenv('PACKETEXCHANGE_WEBHOOK_SECRET');
if ($secret === false || $secret === '') {
    http_response_code(500);
    logLine('Set PACKETEXCHANGE_WEBHOOK_SECRET first (see .env.example).', true);
    exit;
}

if ($_SERVER['REQUEST_METHOD'] !== 'POST' || parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH) !== '/webhooks') {
    http_response_code(404);
    exit;
}

$rawBody = (string) file_get_contents('php://input');
[$ok, $detail] = verify($secret, $rawBody);
if (!$ok) {
    logLine("Rejected delivery: {$detail}", true);
    http_response_code(401);
    header('Content-Type: text/plain');
    echo $detail;
    exit;
}

$delivery = json_decode($rawBody, true, 512, JSON_THROW_ON_ERROR);
$deliveryId = $_SERVER['HTTP_X_WEBHOOK_ID'] ?? '';
logLine("Received {$delivery['event']} (delivery {$deliveryId}, scheme {$detail})");
// Answer quickly with a 2xx. Do slow work after responding, or queue it, so the
// delivery is not timed out and retried.
header('Content-Type: application/json');
echo json_encode(['received' => true]);
