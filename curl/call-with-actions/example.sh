#!/usr/bin/env bash
# Call a customer to confirm an appointment: the answered call speaks a message, asks
# for one key press, and the script follows the call until it ends.
#
#   ./call-with-actions/example.sh +14155550100 +14155550199
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

if [ "$#" -ne 2 ]; then
  echo "Usage: call-with-actions/example.sh <to> <caller-id>" >&2
  exit 2
fi
to="$1"
caller_id="$2"
if [ -z "${PACKETEXCHANGE_API_KEY:-}" ]; then
  echo "Set PACKETEXCHANGE_API_KEY first (see .env.example)." >&2
  exit 2
fi

# What the answered call does, in order. The call hangs up after the last action.
# async: true answers as soon as the number is being dialled (HTTP 202, status ringing)
# instead of holding the request open until the call ends.
body="$(jq -nc --arg to "$to" --arg from "$caller_id" '{
  to: $to, from: $from, maxDuration: 120, async: true, language: "en",
  actions: [
    {say: "Hello, this is Riverside Clinic calling about your appointment tomorrow at 10:30."},
    {gather: {digits: 1, timeout: 5, say: "Press 1 to confirm, or 2 if you need to reschedule."}},
    {say: "Thank you. Goodbye."}
  ]}')"
placed="$(px POST /comms/calls "$body" -H "X-Idempotency-Key: $(idempotency_key)")"
call_id="$(jq -r '.data.callId' <<<"$placed")"
last_status="$(jq -r '.data.status' <<<"$placed")"
echo "Call placed: $call_id (status $last_status)"

# Poll the call until it ends. In production, the call.answered, call.gathered and
# call.completed webhooks tell you the same without polling.
deadline=$((SECONDS + 300))
while true; do
  call="$(px GET "/comms/calls/$(jq -rn --arg id "$call_id" '$id | @uri')")"
  status="$(jq -r '.data.status' <<<"$call")"
  if [ "$status" != "$last_status" ]; then
    echo "  status: $status"
    last_status="$status"
  fi
  case "$status" in
    completed | no_answer | busy | failed)
      # Gathered digits are filled in when the call ends.
      jq -r '.data | "Call ended: \(.status)", "  durationSeconds: \(.durationSeconds // 0)",
        "  cost: \(.cost // "none")", "  hangupReason: \(.hangupReason // "none")",
        "  keyPressed: \(([.gathered // [] | .[] | select(.index == 0) | .digits] | first) // "none")"' <<<"$call"
      exit 0
      ;;
  esac
  if [ $((SECONDS + 2)) -gt "$deadline" ]; then
    echo "Still running after 5 minutes; check GET /comms/calls/$call_id later."
    exit 0
  fi
  sleep 2
done
