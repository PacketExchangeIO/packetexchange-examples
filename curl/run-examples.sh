#!/usr/bin/env bash
# Runs every curl example against the mock API. Use it through scripts/with-mock.sh:
#
#   scripts/with-mock.sh curl/run-examples.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=../scripts/lib.sh
source ../scripts/lib.sh

group=6a1f7c0e-3b4d-4c55-9a8e-2f0d9c1b7e21
sku=b2c4e6f8-1a3c-4e5f-8a9b-0c1d2e3f4a5b
some_id=3d4c2b1a-9e8f-4a7b-8c6d-5e4f3a2b1c0d
delivered_sms=5d0c8a1e-2f3b-4c6d-9e7f-8a9b0c1d2e3f

expect_output 0 "Check result: approved" ./verify-sms/example.sh +14155550100 <<<"123456"
expect_output 0 "Check result: denied (wrong_code)" ./verify-sms/example.sh +14155550100 <<<"000000"
expect_output 1 "Error 400 VALIDATION_ERROR" ./verify-sms/example.sh +15005550000 </dev/null
expect_output 0 "Check result: approved" ./verify-voice/example.sh +14155550100 +14155550199 es <<<"123456"
expect_exit 2 ./verify-voice/example.sh +14155550100
expect_output 0 "Status lookup: accepted" ./send-sms/example.sh +14155550100 Riverside
expect_output 1 "  - to: Must be a valid E.164 phone number" ./send-sms/example.sh 12 Riverside
expect_output 0 "Ledger entry: -" ./make-call/example.sh +14155550100 +14155550199 30
expect_output 0 "Strategy best_quality:" ./price-a-number/example.sh +447700900123
expect_output 0 "/msg" ./price-a-number/example.sh 447700900123 sms
expect_output 0 "skuId $sku" ./phone-numbers/example.sh search 1415
expect_output 2 "Re-run with --confirm" ./phone-numbers/example.sh buy "$group" "$sku"
expect_output 0 "number: pending" ./phone-numbers/example.sh buy "$group" "$sku" --confirm
expect_output 0 "now routes to sip sip.example.com:5060" ./phone-numbers/example.sh route "$some_id" sip sip.example.com:5060
expect_output 0 "Simulated reply:" ./ai-voice-agent/example.sh
expect_output 0 "Attached agent to campaign $some_id" ./ai-voice-agent/example.sh "$some_id"
expect_output 0 "displayedCorrectly: true" ./caller-id-test/example.sh "$some_id" +14155550199 "United States"
expect_output 0 "sms: 0.005900/msg" ./number-lookup/example.sh +447700900123
expect_output 0 "Not a valid number:" ./number-lookup/example.sh 07700900123
# A live-style key makes the mock answer 202 and move the call on at each status read.
PACKETEXCHANGE_API_KEY=wmmn_live_sk_mock expect_output 0 "keyPressed: 1" ./call-with-actions/example.sh +14155550100 +14155550199
expect_output 0 "keyPressed: none" ./call-with-actions/example.sh +14155550100 +14155550199
expect_output 1 "Error 400 VALIDATION_ERROR" ./call-with-actions/example.sh +15005550000 +14155550199
expect_output 0 "delivered at" ./sms-status/example.sh "$delivered_sms"
expect_output 1 "No message $some_id" ./sms-status/example.sh "$some_id"

expect_output 2 "Set PACKETEXCHANGE_API_KEY first" env -u PACKETEXCHANGE_API_KEY ./send-sms/example.sh +14155550100 Riverside

# Webhooks: curl cannot receive requests, so the curl example verifies a captured delivery.
# send-webhook.mjs writes one freshly signed delivery to files for it to check.
export PACKETEXCHANGE_WEBHOOK_SECRET="${PACKETEXCHANGE_WEBHOOK_SECRET:-$(openssl rand -hex 24)}"
delivery="$(mktemp -d)"
node ../mock/send-webhook.mjs --emit-dir "$delivery"
expect_output 0 "Signature valid (scheme v1): sms.sent" \
  ./webhooks/example.sh "$delivery/body.json" "$(cat "$delivery/timestamp")" "$(cat "$delivery/signature")"
expect_output 0 "Signature valid (scheme legacy): sms.sent" \
  ./webhooks/example.sh --legacy "$delivery/body.json" "$(cat "$delivery/legacy-signature")"
expect_output 1 "timestamp outside the 5-minute window" \
  ./webhooks/example.sh "$delivery/body.json" "$(($(cat "$delivery/timestamp") - 600))" "$(cat "$delivery/signature")"
expect_output 1 "invalid v1 signature" \
  ./webhooks/example.sh "$delivery/body.json" "$(cat "$delivery/timestamp")" "v1=$(printf '0%.0s' {1..64})"
rm -rf "$delivery"

finish
