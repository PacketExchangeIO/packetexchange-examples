<p align="center">
  <img src="assets/logo.png" alt="PacketExchange" width="96" height="96">
</p>

<h1 align="center">PacketExchange API examples</h1>

<p align="center">Runnable examples for the PacketExchange voice and SMS API in eight languages.</p>

<p align="center">
  <a href="https://github.com/PacketExchangeIO/packetexchange-examples/actions/workflows/ci.yml"><img src="https://github.com/PacketExchangeIO/packetexchange-examples/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License: MIT"></a>
</p>

Each example is one short, self-contained program that calls the
[PacketExchange REST API](https://packetexchange.io/api-docs) directly over HTTP, with no SDK
in between, so you can see every request and response. Verify a phone number, send a
transactional SMS and follow its delivery, place a call that speaks and collects a key press,
look up and price a number, receive signed webhooks, buy a phone number, build an AI voice
agent, test a caller ID, or top up with USDC.

The same example behaves the same way in every language: the same arguments, the same
output and the same error handling (see [CONVENTIONS.md](CONVENTIONS.md)). Every example
runs in CI against a local [mock API](mock), never the live one.

## Examples

| Example | curl | Node.js | Python | PHP | Go | Java | C# | Ruby |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **Verify by SMS**: send a one-time code, check it | [curl](curl/verify-sms) | [Node.js](node/verify-sms) | [Python](python/verify-sms) | [PHP](php/verify-sms) | [Go](go/verify-sms) | [Java](java/verify-sms) | [C#](csharp/verify-sms) | [Ruby](ruby/verify-sms) |
| **Verify by voice**: the same, read out by a call | [curl](curl/verify-voice) | [Node.js](node/verify-voice) | [Python](python/verify-voice) | [PHP](php/verify-voice) | [Go](go/verify-voice) | [Java](java/verify-voice) | [C#](csharp/verify-voice) | [Ruby](ruby/verify-voice) |
| **Send an SMS**: a transactional reminder and its status | [curl](curl/send-sms) | [Node.js](node/send-sms) | [Python](python/send-sms) | [PHP](php/send-sms) | [Go](go/send-sms) | [Java](java/send-sms) | [C#](csharp/send-sms) | [Ruby](ruby/send-sms) |
| **SMS delivery status**: the timeline from queued to delivered | [curl](curl/sms-status) | [Node.js](node/sms-status) | [Python](python/sms-status) | [PHP](php/sms-status) | [Go](go/sms-status) | [Java](java/sms-status) | [C#](csharp/sms-status) | [Ruby](ruby/sms-status) |
| **Make a call**: outcome, duration and cost | [curl](curl/make-call) | [Node.js](node/make-call) | [Python](python/make-call) | [PHP](php/make-call) | [Go](go/make-call) | [Java](java/make-call) | [C#](csharp/make-call) | [Ruby](ruby/make-call) |
| **Call with actions**: speak, collect a key press, follow the call | [curl](curl/call-with-actions) | [Node.js](node/call-with-actions) | [Python](python/call-with-actions) | [PHP](php/call-with-actions) | [Go](go/call-with-actions) | [Java](java/call-with-actions) | [C#](csharp/call-with-actions) | [Ruby](ruby/call-with-actions) |
| **Price a number**: rank routes by real cost, preview routing | [curl](curl/price-a-number) | [Node.js](node/price-a-number) | [Python](python/price-a-number) | [PHP](php/price-a-number) | [Go](go/price-a-number) | [Java](java/price-a-number) | [C#](csharp/price-a-number) | [Ruby](ruby/price-a-number) |
| **Number lookup**: type, network, risk flags and cheapest price | [curl](curl/number-lookup) | [Node.js](node/number-lookup) | [Python](python/number-lookup) | [PHP](php/number-lookup) | [Go](go/number-lookup) | [Java](java/number-lookup) | [C#](csharp/number-lookup) | [Ruby](ruby/number-lookup) |
| **Webhooks**: receive deliveries and verify signatures | [curl](curl/webhooks) | [Node.js](node/webhooks) | [Python](python/webhooks) | [PHP](php/webhooks) | [Go](go/webhooks) | [Java](java/webhooks) | [C#](csharp/webhooks) | [Ruby](ruby/webhooks) |
| **Phone numbers**: search, buy and route a number | [curl](curl/phone-numbers) | [Node.js](node/phone-numbers) | [Python](python/phone-numbers) | [PHP](php/phone-numbers) | [Go](go/phone-numbers) | [Java](java/phone-numbers) | [C#](csharp/phone-numbers) | [Ruby](ruby/phone-numbers) |
| **AI voice agent**: create, simulate, attach to a campaign | [curl](curl/ai-voice-agent) | [Node.js](node/ai-voice-agent) | [Python](python/ai-voice-agent) | [PHP](php/ai-voice-agent) | [Go](go/ai-voice-agent) | [Java](java/ai-voice-agent) | [C#](csharp/ai-voice-agent) | [Ruby](ruby/ai-voice-agent) |
| **Caller-ID test**: see which caller ID a route delivers | [curl](curl/caller-id-test) | [Node.js](node/caller-id-test) | [Python](python/caller-id-test) | [PHP](php/caller-id-test) | [Go](go/caller-id-test) | [Java](java/caller-id-test) | [C#](csharp/caller-id-test) | [Ruby](ruby/caller-id-test) |
| **x402 top-up**: add funds with USDC on Base |  | [Node.js](node/x402-topup) | [Python](python/x402-topup) |  |  |  |  |  |

Each example folder has a README with what it does, what it costs and how to run it. Each
language folder has a README with its toolchain and setup.

## Prerequisites

- A PacketExchange account with credit and an API key from
  [https://packetexchange.io/dashboard/api-keys](https://packetexchange.io/dashboard/api-keys).
  Sign up at [packetexchange.io](https://packetexchange.io) and add credit first: calls,
  messages, verification codes, phone numbers and caller-ID tests are billed to your balance.
- The toolchain for your language, listed in its README: Bash with `curl` and `jq`,
  Node.js 22.18+, Python 3.12+, PHP 8.3+, Go 1.23+, Java 17+, .NET 8 or Ruby 3.2+.
- Node.js 22, if you want to run the mock API.

## Quick start

```bash
git clone https://github.com/PacketExchangeIO/packetexchange-examples.git
cd packetexchange-examples/python
pip install -r requirements.txt

export PACKETEXCHANGE_API_KEY=wmmn_live_sk_...   # your key; never commit it
python price-a-number/main.py +447700900123
```

To try any example without an account or spending anything, run it against the mock API:

```bash
node mock/server.mjs &                                        # from the repository root
export PACKETEXCHANGE_BASE_URL=http://127.0.0.1:4010/api/v1
export PACKETEXCHANGE_API_KEY=wmmn_test_sk_mock
```

Or run a whole language's examples the way CI does:

```bash
scripts/with-mock.sh node/run-examples.sh
```

## Configuration

| Variable | Used for |
| --- | --- |
| `PACKETEXCHANGE_API_KEY` | Your API key, sent as `Authorization: Bearer <key>`. Required by every API example |
| `PACKETEXCHANGE_BASE_URL` | Optional. Defaults to `https://packetexchange.io/api/v1` |
| `PACKETEXCHANGE_WEBHOOK_SECRET` | The signing secret of your webhook endpoint (`webhooks`) |
| `PORT` | The port the webhook receiver listens on, default `3000` (`webhooks`) |
| `X402_PRIVATE_KEY` | The paying wallet's private key (`x402-topup`) |

See [`.env.example`](.env.example).

## Costs

Most examples spend credit, because they do real things: a verification code is billed as
the SMS or call that carries it, messages per segment, calls per billing increment, and a
caller-ID test $0.50, charged only if the route rang. Looking up a number and reading a
message's or call's status are free. Each example's README states its cost.

Two examples go further and require an explicit `--confirm` flag before they spend:
`phone-numbers buy` (setup price plus the first month) and `x402-topup` (moves USDC from your
wallet). Without the flag they explain what would happen and stop.

## Security notes

- Keep API keys, webhook secrets and wallet keys out of source code and out of version
  control. The examples read them from environment variables only.
- Prefer a scoped API key with only the scopes an integration needs (for example `sms:send`
  or `verify:write`), and revoke any key that may have been exposed.
- Verify every webhook signature before trusting a delivery, over the raw body, and reject
  timestamps older than 5 minutes. The [webhooks](node/webhooks) examples show how.
- Send an `X-Idempotency-Key` on requests that send, dial or buy, so a retry never acts twice.
  The examples do this on every such request.
- Before signing an x402 payment, check the network, token contract and amount in the
  challenge, as the `x402-topup` examples do.
- Use messaging and calling only for recipients who expect them, such as verification codes,
  reminders and confirmations.

Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md).

## Links

- Developer hub: [https://packetexchange.io/developers](https://packetexchange.io/developers)
- API reference: [https://packetexchange.io/api-docs](https://packetexchange.io/api-docs)
- API keys: [https://packetexchange.io/dashboard/api-keys](https://packetexchange.io/dashboard/api-keys)
- Support: [support@packetexchange.io](mailto:support@packetexchange.io)

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) and
[CONVENTIONS.md](CONVENTIONS.md), and follow the [Code of Conduct](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE)
