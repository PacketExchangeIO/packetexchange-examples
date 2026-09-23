<?php

// Search for a phone number, buy it, and point its calls at a SIP server or another number.
// Buying charges the setup price plus the first month, so it needs --confirm.
//
//   php phone-numbers/index.php search 1415
//   php phone-numbers/index.php buy <groupId> <skuId> --confirm
//   php phone-numbers/index.php route <didId> sip sip.example.com:5060
//   php phone-numbers/index.php route <didId> forward +14155550123

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

const USAGE = <<<'TXT'
    Usage: php phone-numbers/index.php search [pattern]
           php phone-numbers/index.php buy <groupId> <skuId> --confirm
           php phone-numbers/index.php route <didId> sip|forward <target>
    TXT;

/** While the number store is switched off, these endpoints answer 200 with { disabled, message }. */
function exitIfStoreDisabled(?array $data): void
{
    if (!empty($data['disabled'])) {
        echo "Number store unavailable: {$data['message']}" . PHP_EOL;
        exit(0);
    }
}

function search(?string $pattern): void
{
    $query = ['limit' => 5] + ($pattern !== null ? ['pattern' => $pattern] : []);
    // Search results are top-level fields of the body, not wrapped in `data`.
    $body = api('GET', '/dids/search?' . http_build_query($query));
    exitIfStoreDisabled($body['data'] ?? null);
    $hits = $body['hits'] ?? [];
    echo count($hits) . ' number groups found:' . PHP_EOL;
    foreach ($hits as $h) {
        $place = $h['city'] ? "{$h['country']}, {$h['city']}" : $h['country'];
        echo "  {$h['dialingPrefix']}  {$place}  " . ($h['typeName'] ?? '') . "  groupId {$h['groupId']}" . PHP_EOL;
        foreach ($h['skus'] as $s) {
            printf(
                "    skuId %s: setup $%.2f, monthly $%.2f, %d channels\n",
                $s['skuId'],
                $s['setupPrice'],
                $s['monthlyPrice'],
                $s['channels'],
            );
        }
    }
}

function buy(string $groupId, string $skuId, bool $confirmed): void
{
    if (!$confirmed) {
        fwrite(STDERR, 'Buying a number charges the setup price plus the first month to your balance.' . PHP_EOL);
        fwrite(STDERR, 'Re-run with --confirm to place the order.' . PHP_EOL);
        exit(2);
    }
    // This spends money. The idempotency key guarantees a retried request orders one number, not two.
    $did = api(
        'POST',
        '/dids/buy',
        ['groupId' => $groupId, 'skuId' => $skuId],
        ['X-Idempotency-Key: ' . uuidV4()],
    )['data'];
    exitIfStoreDisabled($did);
    echo "Number ordered: {$did['id']}" . PHP_EOL;
    echo "  status: {$did['status']}" . PHP_EOL;
    // The number is assigned when provisioning completes; until then it is null.
    echo '  number: ' . ($did['number'] ?? 'pending') . PHP_EOL;
    echo "  setupPrice: {$did['setupPrice']}" . PHP_EOL;
    echo "  monthlyPrice: {$did['monthlyPrice']}" . PHP_EOL;
}

function route(string $didId, string $mode, string $target): void
{
    // sip: host[:port] of your SIP server. forward: an E.164 number to ring instead.
    $did = api('PATCH', '/dids/' . rawurlencode($didId) . '/routing', ['mode' => $mode, 'target' => $target])['data'];
    exitIfStoreDisabled($did);
    echo "Number {$did['id']} now routes to {$did['pointMode']} {$did['pointsTo']}" . PHP_EOL;
}

$confirmed = in_array('--confirm', $argv, true);
$args = array_values(array_filter(array_slice($argv, 1), fn (string $a): bool => $a !== '--confirm'));
if (getenv('PACKETEXCHANGE_API_KEY') === false || getenv('PACKETEXCHANGE_API_KEY') === '') {
    fwrite(STDERR, 'Set PACKETEXCHANGE_API_KEY first (see .env.example).' . PHP_EOL);
    exit(2);
}

$command = $args[0] ?? '';
if ($command === 'search' && count($args) <= 2) {
    search($args[1] ?? null);
} elseif ($command === 'buy' && count($args) === 3) {
    buy($args[1], $args[2], $confirmed);
} elseif ($command === 'route' && count($args) === 4 && in_array($args[2], ['sip', 'forward'], true)) {
    route($args[1], $args[2], $args[3]);
} else {
    fwrite(STDERR, USAGE . PHP_EOL);
    exit(2);
}
