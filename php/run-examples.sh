#!/usr/bin/env bash
# Runs every PHP example against the mock API. Use it through scripts/with-mock.sh:
#
#   scripts/with-mock.sh php/run-examples.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../scripts/lib.sh
source ../scripts/lib.sh

# The PHP command, split into words so a wrapper such as "docker run ... php" also works.
read -ra php <<<"${PHP:-php}"

group=6a1f7c0e-3b4d-4c55-9a8e-2f0d9c1b7e21
sku=b2c4e6f8-1a3c-4e5f-8a9b-0c1d2e3f4a5b
some_id=3d4c2b1a-9e8f-4a7b-8c6d-5e4f3a2b1c0d
delivered_sms=5d0c8a1e-2f3b-4c6d-9e7f-8a9b0c1d2e3f

expect_output 0 "Check result: approved" "${php[@]}" verify-sms/index.php +14155550100 <<<"123456"
expect_output 0 "Check result: denied (wrong_code)" "${php[@]}" verify-sms/index.php +14155550100 <<<"000000"
expect_output 1 "Error 400 VALIDATION_ERROR" "${php[@]}" verify-sms/index.php +15005550000 </dev/null
expect_output 0 "Check result: approved" "${php[@]}" verify-voice/index.php +14155550100 +14155550199 es <<<"123456"
expect_exit 2 "${php[@]}" verify-voice/index.php +14155550100
expect_output 0 "Status lookup: accepted" "${php[@]}" send-sms/index.php +14155550100 Riverside
expect_output 1 "  - to: Must be a valid E.164 phone number" "${php[@]}" send-sms/index.php 12 Riverside
expect_output 0 "Ledger entry: -" "${php[@]}" make-call/index.php +14155550100 +14155550199 30
expect_output 0 "Strategy best_quality:" "${php[@]}" price-a-number/index.php +447700900123
expect_output 0 "/msg" "${php[@]}" price-a-number/index.php 447700900123 sms
expect_output 0 "skuId $sku" "${php[@]}" phone-numbers/index.php search 1415
expect_output 2 "Re-run with --confirm" "${php[@]}" phone-numbers/index.php buy "$group" "$sku"
expect_output 0 "number: pending" "${php[@]}" phone-numbers/index.php buy "$group" "$sku" --confirm
expect_output 0 "now routes to sip sip.example.com:5060" "${php[@]}" phone-numbers/index.php route "$some_id" sip sip.example.com:5060
expect_output 0 "Simulated reply:" "${php[@]}" ai-voice-agent/index.php
expect_output 0 "Attached agent to campaign $some_id" "${php[@]}" ai-voice-agent/index.php "$some_id"
expect_output 0 "displayedCorrectly: true" "${php[@]}" caller-id-test/index.php "$some_id" +14155550199 "United States"
expect_output 0 "sms: 0.005900/msg" "${php[@]}" number-lookup/index.php +447700900123
expect_output 0 "Not a valid number:" "${php[@]}" number-lookup/index.php 07700900123
# A live-style key makes the mock answer 202 and move the call on at each status read.
PACKETEXCHANGE_API_KEY=wmmn_live_sk_mock expect_output 0 "keyPressed: 1" "${php[@]}" call-with-actions/index.php +14155550100 +14155550199
expect_output 0 "keyPressed: none" "${php[@]}" call-with-actions/index.php +14155550100 +14155550199
expect_output 1 "Error 400 VALIDATION_ERROR" "${php[@]}" call-with-actions/index.php +15005550000 +14155550199
expect_output 0 "delivered at" "${php[@]}" sms-status/index.php "$delivered_sms"
expect_output 1 "No message $some_id" "${php[@]}" sms-status/index.php "$some_id"

expect_output 2 "Set PACKETEXCHANGE_API_KEY first" env -u PACKETEXCHANGE_API_KEY "${php[@]}" send-sms/index.php +14155550100 Riverside

# Webhooks: start the receiver, fire signed and unsigned deliveries at it, then stop it.
port="${WEBHOOK_PORT:-3100}"
require_free_port "$port"
export PACKETEXCHANGE_WEBHOOK_SECRET="${PACKETEXCHANGE_WEBHOOK_SECRET:-$(openssl rand -hex 24)}"
"${php[@]}" -S "127.0.0.1:$port" webhooks/index.php &
server_pid=$!
wait_for_port "$port"
expect_exit 0 node ../mock/send-webhook.mjs "http://127.0.0.1:$port/webhooks"
kill "$server_pid"

finish
