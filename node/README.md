# Node.js examples

PacketExchange API examples in TypeScript for Node.js 22, using the built-in `fetch`. No
PacketExchange SDK is involved, so each file shows the raw HTTP API. Node.js runs the `.ts`
files directly.

## Requirements

- Node.js 22.18 or later (TypeScript files run without a build step)
- `npm install` in this folder, for `viem` (used only by `x402-topup` to sign the payment) and
  for type-checking with `npm run lint`

```bash
cd node
npm install
```

## Configure

```bash
export PACKETEXCHANGE_API_KEY=wmmn_live_sk_...   # from https://packetexchange.io/dashboard/api-keys
```

`PACKETEXCHANGE_BASE_URL` overrides the API address (default `https://packetexchange.io/api/v1`).
See [`.env.example`](../.env.example) for every variable.

## Run

From this folder:

```bash
node verify-sms/index.ts +14155550100
node price-a-number/index.ts +447700900123
node phone-numbers/index.ts search 1415
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
| [`x402-topup`](x402-topup) | Top up with USDC on Base over x402 (with `--confirm`) |

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
scripts/with-mock.sh node/run-examples.sh
```
