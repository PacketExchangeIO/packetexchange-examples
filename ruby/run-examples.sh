#!/usr/bin/env bash
# Runs every Ruby example against the mock API. Use it through scripts/with-mock.sh:
#
#   scripts/with-mock.sh ruby/run-examples.sh
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ../scripts/lib.sh

# example <name> <args...>: runs one example.
example() {
  local name="$1"
  shift
  ruby "$name/main.rb" "$@"
}

group=6a1f7c0e-3b4d-4c55-9a8e-2f0d9c1b7e21
sku=b2c4e6f8-1a3c-4e5f-8a9b-0c1d2e3f4a5b
some_id=3d4c2b1a-9e8f-4a7b-8c6d-5e4f3a2b1c0d

expect_output 0 "Check result: approved" example verify-sms +14155550100 <<<"123456"
expect_output 0 "Check result: denied (wrong_code)" example verify-sms +14155550100 <<<"000000"
expect_output 1 "Error 400 VALIDATION_ERROR" example verify-sms +15005550000 </dev/null
expect_output 0 "Check result: approved" example verify-voice +14155550100 +14155550199 es <<<"123456"
expect_exit 2 example verify-voice +14155550100
expect_output 0 "Status lookup: accepted" example send-sms +14155550100 Riverside
expect_output 1 "  - to: Must be a valid E.164 phone number" example send-sms 12 Riverside
expect_output 0 "Ledger entry: -" example make-call +14155550100 +14155550199 30
expect_output 0 "Strategy best_quality:" example price-a-number +447700900123
expect_output 0 "/msg" example price-a-number 447700900123 sms
expect_output 0 "skuId $sku" example phone-numbers search 1415
expect_output 2 "Re-run with --confirm" example phone-numbers buy "$group" "$sku"
expect_output 0 "number: pending" example phone-numbers buy "$group" "$sku" --confirm
expect_output 0 "now routes to sip sip.example.com:5060" example phone-numbers route "$some_id" sip sip.example.com:5060
expect_output 0 "Simulated reply:" example ai-voice-agent
expect_output 0 "Attached agent to campaign $some_id" example ai-voice-agent "$some_id"
expect_output 0 "displayedCorrectly: true" example caller-id-test "$some_id" +14155550199 "United States"

expect_output 2 "Set PACKETEXCHANGE_API_KEY first" env -u PACKETEXCHANGE_API_KEY ruby send-sms/main.rb +14155550100 Riverside

# Webhooks: start the receiver (WEBrick comes from the Gemfile), fire signed and unsigned
# deliveries at it, then stop it.
port="${WEBHOOK_PORT:-3100}"
require_free_port "$port"
export PACKETEXCHANGE_WEBHOOK_SECRET="${PACKETEXCHANGE_WEBHOOK_SECRET:-$(openssl rand -hex 24)}"
PORT="$port" bundle exec ruby webhooks/main.rb &
server_pid=$!
wait_for_port "$port"
expect_exit 0 node ../mock/send-webhook.mjs "http://127.0.0.1:$port/webhooks"
kill "$server_pid"

finish
