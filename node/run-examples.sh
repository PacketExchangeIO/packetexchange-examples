#!/usr/bin/env bash
# Runs every Node.js example against the mock API. Use it through scripts/with-mock.sh:
#
#   scripts/with-mock.sh node/run-examples.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../scripts/lib.sh
source ../scripts/lib.sh

group=6a1f7c0e-3b4d-4c55-9a8e-2f0d9c1b7e21
sku=b2c4e6f8-1a3c-4e5f-8a9b-0c1d2e3f4a5b
some_id=3d4c2b1a-9e8f-4a7b-8c6d-5e4f3a2b1c0d

expect_output 0 "Check result: approved" node verify-sms/index.ts +14155550100 <<<"123456"
expect_output 0 "Check result: denied (wrong_code)" node verify-sms/index.ts +14155550100 <<<"000000"
expect_output 1 "Error 400 VALIDATION_ERROR" node verify-sms/index.ts +15005550000 </dev/null
expect_output 0 "Check result: approved" node verify-voice/index.ts +14155550100 +14155550199 es <<<"123456"
expect_exit 2 node verify-voice/index.ts +14155550100
expect_output 0 "Status lookup: accepted" node send-sms/index.ts +14155550100 Riverside
expect_output 1 "  - to: Must be a valid E.164 phone number" node send-sms/index.ts 12 Riverside
expect_output 0 "Ledger entry: -" node make-call/index.ts +14155550100 +14155550199 30
expect_output 0 "Strategy best_quality:" node price-a-number/index.ts +447700900123
expect_output 0 "/msg" node price-a-number/index.ts 447700900123 sms
expect_output 0 "skuId $sku" node phone-numbers/index.ts search 1415
expect_output 2 "Re-run with --confirm" node phone-numbers/index.ts buy "$group" "$sku"
expect_output 0 "number: pending" node phone-numbers/index.ts buy "$group" "$sku" --confirm
expect_output 0 "now routes to sip sip.example.com:5060" node phone-numbers/index.ts route "$some_id" sip sip.example.com:5060
expect_output 0 "Simulated reply:" node ai-voice-agent/index.ts
expect_output 0 "Attached agent to campaign $some_id" node ai-voice-agent/index.ts "$some_id"
expect_output 0 "displayedCorrectly: true" node caller-id-test/index.ts "$some_id" +14155550199 "United States"

# x402: a throwaway wallet key, generated for this run and never stored.
X402_PRIVATE_KEY="0x$(openssl rand -hex 32)"
export X402_PRIVATE_KEY
expect_output 2 "Payment required: 25 USDC on base" node x402-topup/index.ts 25
expect_output 0 "Top-up confirmed:" node x402-topup/index.ts 25 --confirm

expect_output 2 "Set PACKETEXCHANGE_API_KEY first" env -u PACKETEXCHANGE_API_KEY node send-sms/index.ts +14155550100 Riverside

# Webhooks: start the receiver, fire signed and unsigned deliveries at it, then stop it.
port="${WEBHOOK_PORT:-3100}"
require_free_port "$port"
export PACKETEXCHANGE_WEBHOOK_SECRET="${PACKETEXCHANGE_WEBHOOK_SECRET:-$(openssl rand -hex 24)}"
PORT="$port" node webhooks/index.ts &
server_pid=$!
wait_for_port "$port"
expect_exit 0 node ../mock/send-webhook.mjs "http://127.0.0.1:$port/webhooks"
kill "$server_pid"

finish
