# C# examples

PacketExchange API examples for .NET 8, using `HttpClient` and `System.Text.Json`. No
PacketExchange SDK is involved, so each file shows the raw HTTP API. Each example is a small
console project with one `Program.cs`.

## Requirements

- .NET 8 SDK. There are no NuGet dependencies; `dotnet run` restores and builds each project
  on first use.

## Configure

```bash
export PACKETEXCHANGE_API_KEY=wmmn_live_sk_...   # from https://packetexchange.io/dashboard/api-keys
```

`PACKETEXCHANGE_BASE_URL` overrides the API address (default `https://packetexchange.io/api/v1`).
See [`.env.example`](../.env.example) for every variable.

## Run

From this folder:

```bash
dotnet run --project verify-sms -- +14155550100
dotnet run --project price-a-number -- +447700900123
dotnet run --project phone-numbers -- search 1415
```

Each example prints a usage line when run without arguments.

## Examples

| Example | What it does |
| --- | --- |
| [`verify-sms`](verify-sms) | Send a one-time code by SMS and check it |
| [`verify-voice`](verify-voice) | Send a one-time code by voice call and check it |
| [`send-sms`](send-sms) | Send a transactional SMS and read its status |
| [`make-call`](make-call) | Place a call and read its outcome and cost |
| [`price-a-number`](price-a-number) | Rank routes by real cost for a number and preview routing |
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
scripts/with-mock.sh csharp/run-examples.sh
```
