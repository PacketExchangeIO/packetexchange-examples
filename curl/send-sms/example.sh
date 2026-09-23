#!/usr/bin/env bash
# Send one transactional SMS (an appointment reminder), then look up its status.
#
#   ./send-sms/example.sh +14155550100 Riverside
set -euo pipefail

BASE_URL="${PACKETEXCHANGE_BASE_URL:-https://packetexchange.io/api/v1}"
BASE_URL="${BASE_URL%/}"

# px METHOD PATH [JSON_BODY] [extra curl arguments...]
# Prints the response body on success. On a non-2xx response it prints the API error
# envelope (code, message, field details, request id) to stderr and exits with 1. The
# Authorization header is read from a file descriptor, so the key stays out of the process list.
px() {
  local method="$1" path="$2" body="${3:-}"
  shift $(($# < 3 ? $# : 3))
  local headers body_file status
  headers="$(mktemp)"
  body_file="$(mktemp)"
  if ! status="$(curl -sS -X "$method" "$BASE_URL$path" \
    -H @<(printf 'Authorization: Bearer %s\n' "$PACKETEXCHANGE_API_KEY") \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    ${body:+--data "$body"} "$@" \
    -D "$headers" -o "$body_file" -w '%{http_code}')"; then
    rm -f "$headers" "$body_file"
    echo "Network error: could not reach $BASE_URL" >&2
    exit 1
  fi
  if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
    if jq -e '.error.code' "$body_file" >/dev/null 2>&1; then
      jq -r --arg status "$status" '
        "Error \($status) \(.error.code): \(.error.message)",
        (.error.details | if type == "array" then .[] | "  - \(.path): \(.message)" else empty end)
      ' "$body_file" >&2
    else
      echo "Error $status: $(head -c 200 "$body_file")" >&2
    fi
    local retry_after request_id
    retry_after="$(header_value retry-after "$headers")"
    request_id="$(header_value x-request-id "$headers")"
    if [ "$status" = 429 ] && [ -n "$retry_after" ]; then echo "Retry after: $retry_after seconds" >&2; fi
    if [ -n "$request_id" ]; then echo "Request id: $request_id" >&2; fi
    rm -f "$headers" "$body_file"
    exit 1
  fi
  cat "$body_file"
  rm -f "$headers" "$body_file"
}

# header_value NAME FILE: one response header's value from a curl -D dump.
header_value() {
  grep -i "^$1:" "$2" | tail -n 1 | cut -d: -f2- | tr -d '\r' | sed 's/^ *//' || true
}

# A fresh idempotency key, so a retried request cannot act twice.
idempotency_key() {
  uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid
}

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: send-sms/example.sh <to> <sender-id> [message]" >&2
  exit 2
fi
to="$1"
sender_id="$2"
message="${3:-Reminder: your appointment at Riverside Clinic is tomorrow at 10:30. Call us if you need to reschedule.}"
if [ -z "${PACKETEXCHANGE_API_KEY:-}" ]; then
  echo "Set PACKETEXCHANGE_API_KEY first (see .env.example)." >&2
  exit 2
fi

# Smart Routing picks a route when routeId is omitted. The idempotency key makes a
# retry safe: the same key never sends (or bills) the message twice.
sent="$(px POST /comms/sms "$(jq -nc --arg to "$to" --arg from "$sender_id" --arg msg "$message" \
  '{to: $to, from: $from, message: $msg}')" -H "X-Idempotency-Key: $(idempotency_key)")"
message_id="$(jq -r '.data.messageId' <<<"$sent")"
jq -r '.data | "Message submitted: \(.messageId)", "  status: \(.status)", "  segments: \(.segments)",
  "  cost: \(.cost)"' <<<"$sent"

# The status is the send-time outcome (accepted, sent or failed). Handset delivery
# receipts are not collected, which `dlrSupported: false` states explicitly.
status="$(px GET "/comms/sms/$(jq -rn --arg id "$message_id" '$id | @uri')")"
jq -r '.data | "Status lookup: \(.status)", "  dlrSupported: \(.dlrSupported // false)"' <<<"$status"
