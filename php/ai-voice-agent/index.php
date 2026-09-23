<?php

// Create an AI voice agent, try one conversation turn in text, and optionally attach it
// to a voice campaign so it handles the answered calls.
//
//   php ai-voice-agent/index.php
//   php ai-voice-agent/index.php <campaignId>

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

// The agent's script. A confirmation call to someone who booked an appointment is a
// transactional, expected call; keep agents to calls the recipient has agreed to receive.
const AGENT = [
    'name' => 'Appointment confirmation',
    'language' => 'en',
    'firstMessage' => 'Hello, this is Riverside Clinic calling to confirm your appointment tomorrow at 10:30. '
        . 'Can you still make it?',
    'systemPrompt' => 'You confirm appointments for Riverside Clinic. '
        . 'Ask whether the person can attend their appointment tomorrow at 10:30. '
        . 'If they can, thank them and end the call. '
        . 'If they cannot, offer to have the clinic call them back to reschedule. '
        . 'Keep every reply short and polite.',
    'guardrails' => 'Never ask for payment details, passwords or medical information. '
        . 'If the person asks to stop receiving calls, confirm and end the call.',
    'maxCallSeconds' => 180,
];

if ($argc > 2) {
    fwrite(STDERR, 'Usage: php ai-voice-agent/index.php [campaign-id]' . PHP_EOL);
    exit(2);
}
$campaignId = $argv[1] ?? null;
if (getenv('PACKETEXCHANGE_API_KEY') === false || getenv('PACKETEXCHANGE_API_KEY') === '') {
    fwrite(STDERR, 'Set PACKETEXCHANGE_API_KEY first (see .env.example).' . PHP_EOL);
    exit(2);
}

// Prefer a standard English voice; premium voices are listed too.
$voices = api('GET', '/ai-agents/voices')['data'];
$voice = $voices[0] ?? null;
foreach ($voices as $v) {
    if ($v['language'] === 'en' && !$v['is_pro']) {
        $voice = $v;
        break;
    }
}
if ($voice === null) {
    fwrite(STDERR, 'No voices are available right now.' . PHP_EOL);
    exit(1);
}
echo "Using voice: {$voice['name']} ({$voice['id']})" . PHP_EOL;

$agent = api('POST', '/ai-agents', AGENT + ['voiceId' => $voice['id']])['data'];
echo "Agent created: {$agent['id']}" . PHP_EOL;

// Simulating a turn places no call and is not billed.
$turn = api('POST', "/ai-agents/{$agent['id']}/simulate", ['message' => 'Yes, I can still make it.'])['data'];
echo "Simulated reply: {$turn['reply']}" . PHP_EOL;
echo "  action: {$turn['action']}" . PHP_EOL;

// Agents run on outbound voice campaigns. The campaign must be a draft, ready or paused.
if ($campaignId !== null) {
    api('PUT', '/dialer/campaigns/' . rawurlencode($campaignId), ['aiAgentId' => $agent['id']]);
    echo "Attached agent to campaign {$campaignId}" . PHP_EOL;
}
