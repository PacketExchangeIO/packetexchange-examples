# Python examples

PacketExchange API examples for Python 3.12, using [`httpx`](https://www.python-httpx.org). No
PacketExchange SDK is involved, so each file shows the raw HTTP API.

## Requirements

- Python 3.12 or later
- `httpx`, and `eth-account` for `x402-topup` (it signs the payment)

```bash
cd python
python -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
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
python verify-sms/main.py +14155550100
python price-a-number/main.py +447700900123
python phone-numbers/main.py search 1415
```

Each example prints a usage line when run without arguments. Lint with `ruff check .`.

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
scripts/with-mock.sh python/run-examples.sh
```
