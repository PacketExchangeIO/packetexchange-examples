# Conventions

Every language folder in this repository follows the same layout, inputs, output and
error handling, so an example reads the same whichever language you open. If you add a
language or an example, match this document. If something here is unclear, open an issue
before diverging.

## Folder layout

```text
<language>/
  README.md              # toolchain, install, how to run the examples in this language
  run-examples.sh        # runs every example in this language against the mock API
  <dependency manifest>  # package.json, requirements.txt, go.mod, pom.xml, Gemfile, ...
  <example>/
    README.md            # what it does, cost notes, how to run
    <entry file>         # the example itself, self-contained
```

Example folder names are identical in every language:

| Folder | What it shows |
| --- | --- |
| `verify-sms` | `POST /verify/start` (channel `sms`), then `POST /verify/check` |
| `verify-voice` | The same with channel `voice` |
| `send-sms` | `POST /comms/sms`, then `GET /comms/sms/{messageId}` |
| `make-call` | `POST /comms/calls`, then the matching entry in `GET /comms/calls` |
| `price-a-number` | `GET /routes/price-number`, then `GET /routes/resolve` per strategy |
| `webhooks` | A minimal HTTP server that verifies webhook signatures |
| `phone-numbers` | `GET /dids/search`, `POST /dids/buy`, `PATCH /dids/{id}/routing` |
| `ai-voice-agent` | `GET /ai-agents/voices`, `POST /ai-agents`, `POST /ai-agents/{id}/simulate`, optional `PUT /dialer/campaigns/{id}` |
| `caller-id-test` | `GET /cli-tests/quota`, `POST /cli-tests`, poll `GET /cli-tests/{id}` |
| `x402-topup` | `POST /topups/x402` (node and python only) |

## File naming

One entry file per example, named per language:

| Language | Entry file | Run from the language folder |
| --- | --- | --- |
| curl | `example.sh` | `./verify-sms/example.sh +14155550100` |
| node (TypeScript) | `index.ts` | `node verify-sms/index.ts +14155550100` |
| python | `main.py` | `python verify-sms/main.py +14155550100` |
| php | `index.php` | `php verify-sms/index.php +14155550100` |
| go | `main.go` (one module at `go/`) | `go run ./verify-sms +14155550100` |
| java | `Main.java` | the command in `java/README.md` |
| csharp | `Program.cs` (one project per example) | `dotnet run --project verify-sms -- +14155550100` |
| ruby | `main.rb` | `ruby verify-sms/main.rb +14155550100` |

Each example is **self-contained**: it carries its own small request helper rather than
importing a shared module, so a reader can copy one file and run it. No PacketExchange SDK
is used anywhere: the point is to show the raw HTTP API.

## Environment variables

| Variable | Required | Default | Used by |
| --- | --- | --- | --- |
| `PACKETEXCHANGE_API_KEY` | yes | none | every example except `webhooks` |
| `PACKETEXCHANGE_BASE_URL` | no | `https://packetexchange.io/api/v1` | every API example |
| `PACKETEXCHANGE_WEBHOOK_SECRET` | yes, for `webhooks` | none | `webhooks` |
| `PORT` | no | `3000` | `webhooks` |
| `X402_PRIVATE_KEY` | yes, for `x402-topup` | none | `x402-topup` (hex private key of the paying wallet) |

- The key is sent as `Authorization: Bearer <PACKETEXCHANGE_API_KEY>`.
- Strip one trailing `/` from `PACKETEXCHANGE_BASE_URL` before appending paths.
- If a required variable is missing, print `Set PACKETEXCHANGE_API_KEY first (see .env.example).`
  (or the equivalent for the missing variable) to stderr and exit with code `2`.
- Never read keys from files committed to the repo, never print a key, never hardcode one.
- `.env.example` in the repo root lists every variable. Examples do not load `.env`
  themselves; users `export` the variables or use their own tooling.

## Inputs

- Per-call inputs are **positional arguments**, in the order listed in the example spec below.
- Money-moving actions that are not the point of a normal run require an explicit
  `--confirm` flag (anywhere in the argument list): `phone-numbers buy` and `x402-topup`.
  Without it, print what would happen and exit with code `2`.
- On wrong arguments print a one-line usage (`Usage: <command> <args>`) to stderr and exit `2`.
- Send `Content-Type: application/json` and `Accept: application/json` on every API request.
- Send `X-Idempotency-Key: <random UUID>` on `POST /verify/start`, `POST /comms/sms`,
  `POST /comms/calls` and `POST /dids/buy`, so a retried request cannot act twice.
  Do **not** send it on `POST /topups/x402` (the API does not use it there).

## Output

- Results go to **stdout** as short human-readable lines: a summary line, then selected
  fields indented by two spaces as `  field: value`. The exact lines per example are
  given below; keep the wording identical across languages.
- Money is printed exactly as the API returns it (a 6-decimal string such as `0.012500`).
  Never convert a money string to a float for display or arithmetic. The few prices the API
  returns as JSON numbers (catalogue prices, `costPerTest`) are printed with 2 decimals.
- Errors go to **stderr**.

## Error handling

Every failed request (HTTP status outside 200-299, except the documented `402` in
`x402-topup`) is reported the same way, from the API error envelope
`{ "success": false, "error": { "code", "message", "details": [{ "path", "message" }] } }`:

```text
Error 400 VALIDATION_ERROR: Validation failed
  - to: Must be a valid E.164 phone number (e.g. +14155550100)
Request id: 3f0c2d4e-...
```

- Line 1: `Error <HTTP status> <error.code>: <error.message>`.
- One `  - <path>: <message>` line per item when `error.details` is an array.
- `Request id: <value of the X-Request-Id response header>` when the header is present.
- If the body is not a JSON envelope (a proxy error page, for example), print
  `Error <status>: <first 200 characters of the body>`.
- For `429`, add `Retry after: <Retry-After header> seconds` when the header is present.
- Then exit with code `1`. Network failures (DNS, timeout, refused) also exit `1` with a
  one-line message. Do not print stack traces for expected failures.

Exit codes: `0` success, `1` API or network error, `2` usage error or missing `--confirm`.

## Example specs

The mock API (see [mock/README.md](mock/README.md)) implements exactly these calls.

### verify-sms `<to>`

1. `POST /verify/start` `{ "to": <to>, "channel": "sms" }`. Print:
   ```text
   Verification sent by SMS to <to>
     verificationId: <verificationId>
     expiresAt: <expiresAt>
   ```
   If the response has `testCode` (test keys only), also print `  testCode: <testCode>`.
2. Print the prompt `Enter the code: ` and read one line from stdin.
3. `POST /verify/check` `{ "verificationId", "code" }`. Print
   `Check result: <status>` (append ` (<reason>)` when `reason` is present), then
   `  attemptsRemaining: <n>`. A `denied` result is not an error: exit `0`.

### verify-voice `<to> <caller-id> [language]`

Same as `verify-sms` with `{ "to", "channel": "voice", "from": <caller-id>, "language": <language, default en> }`.
The first summary line is `Verification call placed to <to> (language: <language>)`.
Voice languages: `en, es, fr, de, pt, hi`.

### send-sms `<to> <sender-id> [message]`

Default message: `Reminder: your appointment at Riverside Clinic is tomorrow at 10:30. Call us if you need to reschedule.`

1. `POST /comms/sms` `{ "to", "from": <sender-id>, "message" }`. Print:
   ```text
   Message submitted: <messageId>
     status: <status>
     segments: <segments>
     cost: <cost>
   ```
2. `GET /comms/sms/{messageId}`. Print `Status lookup: <status>` then `  dlrSupported: <true|false>`
   (`false` when the field is absent).

### make-call `<to> <caller-id> [max-duration-seconds]`

Default max duration `60`. `POST /comms/calls` blocks until the call ends, so set the client
timeout to `max-duration + 30` seconds.

1. `POST /comms/calls` `{ "to", "from": <caller-id>, "maxDuration" }`. Print:
   ```text
   Call finished: <callId>
     status: <status>
     durationSeconds: <durationSeconds>
     billableSeconds: <billableSeconds>
     cost: <cost>
     hangupCause: <hangupCause or none>
   ```
2. `GET /comms/calls?limit=25`, find the entry whose `relatedEntityId` or `callId` equals the
   call id. Print `Ledger entry: <amount> (balance after <balanceAfter>)`, or
   `Ledger entry: not in the latest 25 entries`.

### price-a-number `<number> [voice|sms]`

Default type `voice`.

1. `GET /routes/price-number?number=<number>&type=<type>`. Print
   `<total> routes serve <number> (<type>), cheapest first:`, then for the first 5 routes
   `  <rate>/<unit>  <destination>  prefix <matchedPrefix>  ASR <expectedAsr>% (seller-stated)  <id>`
   (`ASR n/a` instead when `expectedAsr` is null).
   If `notice` is `sanctioned`, print `No routes: the destination is embargoed.` instead.
2. For each strategy `cheapest`, `best_quality`, `balanced`:
   `GET /routes/resolve?to=<number>&type=<type>&strategy=<strategy>`. Print
   `Strategy <strategy>: <selected.price>/<unit> via <selected.id> (<selected.destinationName>)`
   or `Strategy <strategy>: no route` when `selected` is null.
   `<unit>` is `min` for voice and `msg` for SMS.

### webhooks

An HTTP server on `PORT` accepting `POST /webhooks` (anything else: `404`).

- Read the **raw** request body bytes; verify before parsing JSON.
- If `X-PX-Signature` is present: require `X-PX-Timestamp`, reject if it is more than
  300 seconds away from now (either direction), and compare `v1=<hex>` against
  `HMAC-SHA256(secret, "<timestamp>.<raw body>")` with a constant-time comparison.
- Only when `X-PX-Signature` is absent, fall back to `X-Webhook-Signature: sha256=<hex>`
  with `HMAC-SHA256(secret, <raw body>)`. The legacy scheme has no replay protection.
- Valid: respond `200` with `{"received":true}` and print
  `Received <event> (delivery <X-Webhook-Id>, scheme <v1|legacy>)`, where `event` comes from
  the JSON body `{ event, data, timestamp }`.
- Invalid or missing signature, or stale timestamp: respond `401` with a short plain-text
  reason and print `Rejected delivery: <reason>` to stderr.
- On start print `Listening on http://localhost:<PORT>/webhooks`.
- PHP runs it under the built-in server (`php -S localhost:<PORT> webhooks/index.php`), which
  prints its own start-up line.
- curl cannot receive requests, so `curl/webhooks/example.sh` is a command-line verifier for a
  captured delivery instead: `example.sh <body-file> <X-PX-Timestamp> <X-PX-Signature>` or
  `example.sh --legacy <body-file> <X-Webhook-Signature>`, printing
  `Signature valid (scheme <v1|legacy>): <event>` or exiting `1` with `Rejected delivery: <reason>`.

### phone-numbers

- `search [pattern]`: `GET /dids/search?limit=5` plus `&pattern=<pattern>` when given. The success
  body is `{ success, hits, scannedPages, truncated }` (not wrapped in `data`). If the body
  has `data.disabled`, print `Number store unavailable: <data.message>` and exit `0`. Otherwise
  print `<n> number groups found:` then per hit
  `  <dialingPrefix>  <country>[, <city>]  <typeName>  groupId <groupId>` and per SKU
  `    skuId <skuId>: setup $<setupPrice>, monthly $<monthlyPrice>, <channels> channels`
  (these two prices are JSON numbers here; print them with 2 decimals).
- `buy <groupId> <skuId> [--confirm]`: without `--confirm` print
  `Buying a number charges the setup price plus the first month to your balance.` and
  `Re-run with --confirm to place the order.` to stderr, exit `2`. With it,
  `POST /dids/buy` `{ "groupId", "skuId" }`. Print `Number ordered: <id>` then
  `  status: <status>`, `  number: <number or pending>`, `  setupPrice: <setupPrice>`,
  `  monthlyPrice: <monthlyPrice>`. Handle `data.disabled` as in `search`.
- `route <didId> sip <host[:port]>` or `route <didId> forward <E.164>`:
  `PATCH /dids/{didId}/routing` `{ "mode", "target" }`. Print
  `Number <id> now routes to <pointMode> <pointsTo>`.

### ai-voice-agent `[campaign-id]`

1. `GET /ai-agents/voices`. Pick the first voice with `language` `en` and `is_pro` false,
   else the first voice. Print `Using voice: <name> (<id>)`.
2. `POST /ai-agents` with `name` `Appointment confirmation`, the chosen `voiceId`,
   `language` `en`, a `firstMessage`, a `systemPrompt`, `guardrails` and
   `maxCallSeconds` `180` (see the node example for the exact texts). Print `Agent created: <id>`.
3. `POST /ai-agents/{id}/simulate` `{ "message": "Yes, I can still make it." }`. Print
   `Simulated reply: <reply>` then `  action: <action>`.
4. Only when `campaign-id` is given: `PUT /dialer/campaigns/{campaign-id}` `{ "aiAgentId": <id> }`.
   Print `Attached agent to campaign <campaign-id>`.

### caller-id-test `<route-id> <caller-id> <country>`

1. `GET /cli-tests/quota`. Print
   `Caller-ID test price: $<costPerTest> per test, charged only if the route rang (<remaining> of <limitPerHour> left this hour)`
   (`costPerTest` is a JSON number; print it with 2 decimals).
2. `POST /cli-tests` `{ "routeId", "displayCli": <caller-id>, "testCountry": <country> }`.
   Print `Test queued: <id> (status <status>)`.
3. Poll `GET /cli-tests/{id}`: request immediately, then every 10 seconds, for at most
   10 minutes, until `status` is `completed`, `failed`, `not_tested` or `cancelled`. Print
   `  status: <status>` each time it changes. Then print `Result: <status>`,
   `  reportedCli: <reportedCli or none>`, `  displayedCorrectly: <value or unknown>`,
   `  resultNotes: <resultNotes or none>`. On timeout print
   `Still running after 10 minutes; check GET /cli-tests/<id> later.` and exit `0`.

### x402-topup `<amount-usd> [--confirm]` (node and python only)

1. `POST /topups/x402` `{ "amountUsd": <number> }` without `X-PAYMENT`. A `201` means x402 is
   not enabled: print `x402 top-ups are not enabled: <data.message>`, exit `0`. A `402` carries
   `{ x402Version, accepts: [requirements], error }`. Check the requirements before signing:
   `scheme` is `exact`; `network` is `base` or `base-sepolia`; `asset` is the USDC contract for
   that network; `maxAmountRequired` equals the amount in USDC atomic units (6 decimals).
   Print `Payment required: <amount> USDC on <network> to <payTo>`.
2. Without `--confirm`: print `Re-run with --confirm to sign and send this payment.` to stderr, exit `2`.
3. With it: sign an EIP-3009 `TransferWithAuthorization` with `X402_PRIVATE_KEY`, send it
   base64-encoded in `X-PAYMENT`, and repeat the same POST. Print
   `Top-up confirmed: <topupId>`, `  txHash: <txHash>`, `  newBalance: <newBalance>`.

## Running against the mock

The mock is a dependency-free Node 22 server in [`mock/`](mock/). From the repo root:

```bash
# Starts the mock on 127.0.0.1:4010, runs the command with PACKETEXCHANGE_BASE_URL and a
# placeholder PACKETEXCHANGE_API_KEY set, then stops the mock.
scripts/with-mock.sh node/run-examples.sh
```

Each `<language>/run-examples.sh`:

- is executable, starts with `#!/usr/bin/env bash` and `set -euo pipefail`, and `cd`s into its own folder;
- sources `../scripts/lib.sh` (preceded by `# shellcheck source=../scripts/lib.sh`), uses `expect_exit <code> <command...>` or
  `expect_output <code> <text> <command...>` for every case, and ends with `finish`;
- runs every example at least once on the success path, plus the negative cases listed below;
- for `webhooks`, takes the port from `WEBHOOK_PORT` (default `3100`), calls
  `require_free_port`, starts the server in the background, waits with `wait_for_port`, runs
  `node ../mock/send-webhook.mjs http://127.0.0.1:<port>/webhooks` (six signed and unsigned
  deliveries, each response code checked), then stops the server. The node runner is the
  reference for this block.

Mock fixtures to test against:

- Any key starting with `wmmn_` is accepted. The runner uses `wmmn_test_sk_mock`, so
  `POST /verify/start` returns `testCode`. The code is always `123456`.
- Numbers must match `^\+?[1-9][0-9]{6,14}$`; `+15005550000` is refused with a `400` for any
  send, which is the standard negative case.
- `phone-numbers search` returns groupId `6a1f7c0e-3b4d-4c55-9a8e-2f0d9c1b7e21` with skuId `b2c4e6f8-1a3c-4e5f-8a9b-0c1d2e3f4a5b`.
- Any UUID works as a route id, DID id or campaign id; a malformed id returns `400`.
- x402: the challenge is for network `base`; the mock checks the payment's structure,
  amount, recipient and validity window, and reports a fake transaction hash.

Required cases in every `run-examples.sh` (skip `x402-topup` outside node and python):

| Case | Expected exit |
| --- | --- |
| `verify-sms +14155550100` with stdin `123456` | 0, prints `Check result: approved` |
| `verify-sms +14155550100` with stdin `000000` | 0, prints `Check result: denied (wrong_code)` |
| `verify-sms +15005550000` | 1, prints `Error 400 VALIDATION_ERROR` |
| `verify-voice +14155550100 +14155550199 es` with stdin `123456` | 0 |
| `verify-voice +14155550100` | 2 |
| `send-sms +14155550100 Riverside` | 0 |
| `send-sms 12 Riverside` | 1 |
| `make-call +14155550100 +14155550199 30` | 0 |
| `price-a-number +447700900123` and `price-a-number 447700900123 sms` | 0 |
| `phone-numbers search 1415` | 0 |
| `phone-numbers buy <groupId> <skuId>` | 2 |
| `phone-numbers buy <groupId> <skuId> --confirm` | 0 |
| `phone-numbers route <uuid> sip sip.example.com:5060` | 0 |
| `ai-voice-agent` and `ai-voice-agent <uuid>` | 0 |
| `caller-id-test <uuid> +14155550199 "United States"` | 0 |
| `x402-topup 25` | 2 |
| `x402-topup 25 --confirm` (with a throwaway `X402_PRIVATE_KEY` generated at runtime) | 0 |
| `webhooks` via `send-webhook.mjs` | 0 |
| Any API example with `PACKETEXCHANGE_API_KEY` unset | 2 |

## CI job shape

`.github/workflows/ci.yml` has one job per language, all with the same steps:

1. `actions/checkout@v7`
2. `actions/setup-node@v7` with `node-version: 22` (every job needs Node for the mock)
3. The language toolchain (`actions/setup-python@v7` 3.12, `shivammathur/setup-php@v2` 8.3,
   `actions/setup-go@v7` 1.23, `actions/setup-java@v6` 17 temurin, `actions/setup-dotnet@v6` 8.0.x,
   `ruby/setup-ruby@v1` 3.2)
4. Install dependencies
5. Lint or build (for example `tsc --noEmit`, `ruff check`, `php -l`, `go vet`, `javac`/`mvn -q compile`,
   `dotnet build`, `ruby -wc`)
6. `scripts/with-mock.sh <language>/run-examples.sh`

Keep dependency manifests where `dependabot.yml` expects them: `node/package.json`,
`python/requirements.txt`, `go/go.mod`, `java/pom.xml`, `csharp/*/*.csproj`, `ruby/Gemfile`.

## Style

- Comments explain why, briefly. No file-top banners.
- No em dashes in code, comments or docs.
- Keep each example short enough to read in one sitting; prefer clarity over abstraction.
- Every example README has: a one-paragraph description, a **Cost** section, a **Run** section
  (with a mock command), and links to the API reference.
