#!/usr/bin/env bash
# Place one outbound call and read its outcome and cost, then find its ledger entry.
# POST /comms/calls returns when the call has ended, so the client waits for it.
#
#   ./make-call/example.sh +14155550100 +14155550199 60
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

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ] || ! [[ "${3:-60}" =~ ^[0-9]+$ ]]; then
  echo "Usage: make-call/example.sh <to> <caller-id> [max-duration-seconds]" >&2
  exit 2
fi
to="$1"
caller_id="$2"
max_duration="${3:-60}"
if [ -z "${PACKETEXCHANGE_API_KEY:-}" ]; then
  echo "Set PACKETEXCHANGE_API_KEY first (see .env.example)." >&2
  exit 2
fi

# The request stays open until the call is answered and hung up, not answered, or
# reaches maxDuration, so the client timeout (--max-time) must be longer than maxDuration.
call="$(px POST /comms/calls "$(jq -nc --arg to "$to" --arg from "$caller_id" --argjson max "$max_duration" \
  '{to: $to, from: $from, maxDuration: $max}')" \
  -H "X-Idempotency-Key: $(idempotency_key)" --max-time "$((max_duration + 30))")"
call_id="$(jq -r '.data.callId' <<<"$call")"
jq -r '.data | "Call finished: \(.callId)", "  status: \(.status)", "  durationSeconds: \(.durationSeconds)",
  "  billableSeconds: \(.billableSeconds)", "  cost: \(.cost)", "  hangupCause: \(.hangupCause // "none")"' <<<"$call"

# Call history is the account ledger, newest first; the entry references the call id.
px GET "/comms/calls?limit=25" | jq -r --arg id "$call_id" '
  [.data[] | select(.relatedEntityId == $id or .callId == $id)][0]
  | if . then "Ledger entry: \(.amount) (balance after \(.balanceAfter))"
    else "Ledger entry: not in the latest 25 entries" end'
