# Ruby examples

PacketExchange API examples for Ruby 3.2, using `net/http` and `json` from the standard
library. No PacketExchange SDK is involved, so each file shows the raw HTTP API.

## Requirements

- Ruby 3.2 or later
- Bundler, for the `webrick` gem that the `webhooks` server needs (it is no longer bundled
  with Ruby). The API examples need no gems.

```bash
cd ruby
bundle install
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
ruby verify-sms/main.rb +14155550100
ruby price-a-number/main.rb +447700900123
ruby phone-numbers/main.rb search 1415
```

Each example prints a usage line when run without arguments. Check syntax with `ruby -wc <file>`.

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
scripts/with-mock.sh ruby/run-examples.sh
```
