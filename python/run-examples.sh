#!/usr/bin/env bash
# Runs every Python example against the mock API. Use it through scripts/with-mock.sh:
#
#   scripts/with-mock.sh python/run-examples.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../scripts/lib.sh
source ../scripts/lib.sh

# Use the interpreter from an activated virtualenv when there is one.
PYTHON="${PYTHON:-python3}"
# Keep stdout and stderr in order when both are captured.
export PYTHONUNBUFFERED=1

group=6a1f7c0e-3b4d-4c55-9a8e-2f0d9c1b7e21
sku=b2c4e6f8-1a3c-4e5f-8a9b-0c1d2e3f4a5b
some_id=3d4c2b1a-9e8f-4a7b-8c6d-5e4f3a2b1c0d

expect_output 0 "Check result: approved" "$PYTHON" verify-sms/main.py +14155550100 <<<"123456"
expect_output 0 "Check result: denied (wrong_code)" "$PYTHON" verify-sms/main.py +14155550100 <<<"000000"
expect_output 1 "Error 400 VALIDATION_ERROR" "$PYTHON" verify-sms/main.py +15005550000 </dev/null
expect_output 0 "Check result: approved" "$PYTHON" verify-voice/main.py +14155550100 +14155550199 es <<<"123456"
expect_exit 2 "$PYTHON" verify-voice/main.py +14155550100
expect_output 0 "Status lookup: accepted" "$PYTHON" send-sms/main.py +14155550100 Riverside
expect_output 1 "  - to: Must be a valid E.164 phone number" "$PYTHON" send-sms/main.py 12 Riverside
expect_output 0 "Ledger entry: -" "$PYTHON" make-call/main.py +14155550100 +14155550199 30
expect_output 0 "Strategy best_quality:" "$PYTHON" price-a-number/main.py +447700900123
expect_output 0 "/msg" "$PYTHON" price-a-number/main.py 447700900123 sms
expect_output 0 "skuId $sku" "$PYTHON" phone-numbers/main.py search 1415
expect_output 2 "Re-run with --confirm" "$PYTHON" phone-numbers/main.py buy "$group" "$sku"
expect_output 0 "number: pending" "$PYTHON" phone-numbers/main.py buy "$group" "$sku" --confirm
expect_output 0 "now routes to sip sip.example.com:5060" "$PYTHON" phone-numbers/main.py route "$some_id" sip sip.example.com:5060
expect_output 0 "Simulated reply:" "$PYTHON" ai-voice-agent/main.py
expect_output 0 "Attached agent to campaign $some_id" "$PYTHON" ai-voice-agent/main.py "$some_id"
expect_output 0 "displayedCorrectly: true" "$PYTHON" caller-id-test/main.py "$some_id" +14155550199 "United States"

# x402: a throwaway wallet key, generated for this run and never stored.
X402_PRIVATE_KEY="0x$(openssl rand -hex 32)"
export X402_PRIVATE_KEY
expect_output 2 "Payment required: 25 USDC on base" "$PYTHON" x402-topup/main.py 25
expect_output 0 "Top-up confirmed:" "$PYTHON" x402-topup/main.py 25 --confirm

expect_output 2 "Set PACKETEXCHANGE_API_KEY first" env -u PACKETEXCHANGE_API_KEY "$PYTHON" send-sms/main.py +14155550100 Riverside

# Webhooks: start the receiver, fire signed and unsigned deliveries at it, then stop it.
port="${WEBHOOK_PORT:-3100}"
require_free_port "$port"
export PACKETEXCHANGE_WEBHOOK_SECRET="${PACKETEXCHANGE_WEBHOOK_SECRET:-$(openssl rand -hex 24)}"
PORT="$port" "$PYTHON" webhooks/main.py &
server_pid=$!
wait_for_port "$port"
expect_exit 0 node ../mock/send-webhook.mjs "http://127.0.0.1:$port/webhooks"
kill "$server_pid"

finish
