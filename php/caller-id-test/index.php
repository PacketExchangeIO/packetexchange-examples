<?php

// Test which caller ID a route really delivers: a test handset in the destination
// country receives a call and reports the number it displayed.
//
//   php caller-id-test/index.php <routeId> +14155550199 "United States"

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

const FINAL_STATUSES = ['completed', 'failed', 'not_tested', 'cancelled'];
const POLL_EVERY_SECONDS = 10;
const GIVE_UP_AFTER_SECONDS = 600;

if ($argc !== 4) {
    fwrite(STDERR, 'Usage: php caller-id-test/index.php <route-id> <caller-id> <country>' . PHP_EOL);
    exit(2);
}
[, $routeId, $callerId, $country] = $argv;
if (getenv('PACKETEXCHANGE_API_KEY') === false || getenv('PACKETEXCHANGE_API_KEY') === '') {
    fwrite(STDERR, 'Set PACKETEXCHANGE_API_KEY first (see .env.example).' . PHP_EOL);
    exit(2);
}

// Each test is a real call. It is charged only if the route rang; the live price is in the quota.
$quota = api('GET', '/cli-tests/quota')['data'];
printf(
    "Caller-ID test price: $%.2f per test, charged only if the route rang (%d of %d left this hour)\n",
    $quota['costPerTest'],
    $quota['remaining'],
    $quota['limitPerHour'],
);

// The country must be the route's own destination country, for example "United Kingdom".
$created = api(
    'POST',
    '/cli-tests',
    ['routeId' => $routeId, 'displayCli' => $callerId, 'testCountry' => $country],
)['data'];
echo "Test queued: {$created['id']} (status {$created['status']})" . PHP_EOL;

$deadline = time() + GIVE_UP_AFTER_SECONDS;
$lastStatus = $created['status'];
while (true) {
    $test = api('GET', "/cli-tests/{$created['id']}")['data'];
    if ($test['status'] !== $lastStatus) {
        echo "  status: {$test['status']}" . PHP_EOL;
        $lastStatus = $test['status'];
    }
    if (in_array($test['status'], FINAL_STATUSES, true)) {
        $correct = $test['displayedCorrectly'];
        echo "Result: {$test['status']}" . PHP_EOL;
        echo '  reportedCli: ' . ($test['reportedCli'] ?? 'none') . PHP_EOL;
        echo '  displayedCorrectly: ' . ($correct === null ? 'unknown' : ($correct ? 'true' : 'false')) . PHP_EOL;
        echo '  resultNotes: ' . ($test['resultNotes'] ?? 'none') . PHP_EOL;
        break;
    }
    if (time() + POLL_EVERY_SECONDS > $deadline) {
        echo "Still running after 10 minutes; check GET /cli-tests/{$created['id']} later." . PHP_EOL;
        break;
    }
    sleep(POLL_EVERY_SECONDS);
}
