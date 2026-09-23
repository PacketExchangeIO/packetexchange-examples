# PHP examples

PacketExchange API examples for PHP 8.3 using the `curl` extension, with no Composer
dependencies. No PacketExchange SDK is involved, so each file shows the raw HTTP API.

## Requirements

- PHP 8.3 or later with the `curl` extension (enabled in most PHP builds)

## Configure

```bash
export PACKETEXCHANGE_API_KEY=wmmn_live_sk_...   # from https://packetexchange.io/dashboard/api-keys
```

`PACKETEXCHANGE_BASE_URL` overrides the API address (default `https://packetexchange.io/api/v1`).
See [`.env.example`](../.env.example) for every variable.

## Run

From this folder:

```bash
php verify-sms/index.php +14155550100
php price-a-number/index.php +447700900123
php phone-numbers/index.php search 1415
```

The webhook receiver runs under PHP's built-in server:

```bash
PACKETEXCHANGE_WEBHOOK_SECRET=... php -S localhost:3000 webhooks/index.php
```

Each example prints a usage line when run without arguments.

## Examples

| Example | What it does |
| --- | --- |
| [`verify-sms`](verify-sms) | Send a one-time code by SMS and check it |
| [`verify-voice`](verify-voice) | Send a one-time code by voice call and check it |
| [`send-sms`](send-sms) | Send a transactional SMS and read its status |
| [`sms-status`](sms-status) | Read an SMS's delivery status and timeline |
| [`make-call`](make-call) | Place a call and read its outcome and cost |
| [`call-with-actions`](call-with-actions) | Place a call that speaks and collects a key press, then follow it |
| [`price-a-number`](price-a-number) | Rank routes by real cost for a number and preview routing |
| [`number-lookup`](number-lookup) | Look up a number's type, network, risk flags and cheapest price |
| [`webhooks`](webhooks) | Verify webhook signatures |
| [`phone-numbers`](phone-numbers) | Search, buy (with `--confirm`) and route a phone number |
| [`ai-voice-agent`](ai-voice-agent) | Create an AI voice agent and attach it to a campaign |
| [`caller-id-test`](caller-id-test) | Test which caller ID a route delivers |

`x402-topup` needs a wallet signature, so it is available in [Node.js](../node/x402-topup) and
[Python](../python/x402-topup) only.

## Try it against the mock

The [mock API](../mock) runs every example without an account and without spending anything.
From the repository root:

```bash
node mock/server.mjs &
export PACKETEXCHANGE_BASE_URL=http://127.0.0.1:4010/api/v1
export PACKETEXCHANGE_API_KEY=wmmn_test_sk_mock
```

Or run the whole suite the way CI does:

```bash
scripts/with-mock.sh php/run-examples.sh
```
