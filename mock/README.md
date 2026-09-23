# Mock API

A small, dependency-free Node.js server that stands in for the PacketExchange API, so every
example can run locally and in CI without an account, without spending credit and without
sending a real message or placing a real call.

It implements only the endpoints the examples use, with the same request validation, field
names and response envelopes as the real API (`{ "success": true, "data": ... }` and
`{ "success": false, "error": { "code", "message", "details" } }`). State is kept in memory, so
multi-step flows work: a verification started can be checked, a number bought can be routed.

The mock is a testing aid, not a specification. The [API reference](https://packetexchange.io/api-docs)
is the source of truth.

## Run it

Requires Node.js 22.

```bash
node mock/server.mjs
# PacketExchange mock API listening on http://127.0.0.1:4010/api/v1
```

Then point any example at it:

```bash
export PACKETEXCHANGE_BASE_URL=http://127.0.0.1:4010/api/v1
export PACKETEXCHANGE_API_KEY=wmmn_test_sk_mock
```

`MOCK_PORT` changes the port. To start the mock, run one command against it and stop it again:

```bash
scripts/with-mock.sh node/run-examples.sh
```

## Endpoints

| Method | Path | Notes |
| --- | --- | --- |
| `GET` | `/health` | No key needed |
| `POST` | `/verify/start` | The code is always `123456`; returned as `testCode` for `wmmn_test_sk_` keys |
| `POST` | `/verify/check` | Single use, 5 attempts, expiry, like the real API |
| `GET` | `/verify/{id}` | Returns the verification state, never the code |
| `POST` | `/comms/sms` | Segments counted as GSM-7 or UCS-2 |
| `GET` | `/comms/sms/{messageId}` | Delivery status and timeline. Unknown ids answer `200` with status `not_found`, like the real API |
| `POST` | `/comms/calls` | Checks `actions`. Returns a 42-second answered call (capped at `maxDuration`); with `async: true` and a live-style key, answers `202` instead |
| `GET` | `/comms/calls` | Ledger entries for calls made against this mock |
| `GET` | `/comms/calls/{id}` | Call status; a live async call moves one step (`ringing`, `answered`, `completed`) per read |
| `GET` | `/lookup/{number}` | UK mobiles, US numbers and an embargoed destination (`+53`); malformed numbers answer `valid: false` |
| `GET` | `/routes/price-number` | Three sample routes; numbers starting `53` return `notice: "sanctioned"` |
| `GET` | `/routes/resolve` | Ranks the same routes by `strategy` |
| `GET` | `/dids/search` | One number group (below) |
| `POST` | `/dids/buy` | Returns a `pending` number |
| `PATCH` | `/dids/{id}/routing` | Any well-formed id is treated as your number |
| `GET` | `/ai-agents/voices` | Three sample voices |
| `POST` | `/ai-agents` | Returns the new agent |
| `POST` | `/ai-agents/{id}/simulate` | A fixed reply |
| `PUT` | `/dialer/campaigns/{id}` | Accepts `aiAgentId` |
| `GET` | `/cli-tests/quota` | `costPerTest: 0.5` |
| `POST` | `/cli-tests` |  |
| `GET` | `/cli-tests/{id}` | Completes on the first read, so nothing waits |
| `POST` | `/topups/x402` | `402` challenge on network `base`; checks the payment's structure, amount, recipient and validity window, then reports a fake transaction |

## Fixtures

| Value | Meaning |
| --- | --- |
| Any key starting with `wmmn_` | Accepted. Keys starting `wmmn_test_sk_` behave like test keys (`simulated: true`, `testCode`), keys starting `wmmn_live_sk_` like live keys |
| `5d0c8a1e-2f3b-4c6d-9e7f-8a9b0c1d2e3f` | A delivered SMS with a carrier receipt, for `GET /comms/sms/{messageId}` |
| `123456` | The verification code |
| `+15005550000` | Refused with `400 VALIDATION_ERROR` by every send, to show the error path |
| `6a1f7c0e-3b4d-4c55-9a8e-2f0d9c1b7e21` | The number group id returned by `/dids/search` |
| `b2c4e6f8-1a3c-4e5f-8a9b-0c1d2e3f4a5b` | Its SKU id |

A malformed UUID in a path answers `400 INVALID_INPUT`, and a missing or non-`wmmn_` key
answers `401 UNAUTHORIZED`.

## Webhook sender

`send-webhook.mjs` signs deliveries exactly as PacketExchange does and checks how a receiver
answers. It needs `PACKETEXCHANGE_WEBHOOK_SECRET`, the same secret the receiver uses.

```bash
# Send six deliveries (valid v1, legacy only, stale, wrong signature, altered body, unsigned)
# and check the receiver answers 200, 200, 401, 401, 401, 401.
node mock/send-webhook.mjs http://127.0.0.1:3000/webhooks

# Write one signed delivery to files (body.json, timestamp, signature, legacy-signature).
node mock/send-webhook.mjs --emit-dir /tmp/delivery
```
