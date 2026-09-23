#!/usr/bin/env bash
# Rank every marketplace route for one phone number by what it would really cost, then
# show which route Smart Routing would pick for each strategy.
#
#   ./price-a-number/example.sh +447700900123
#   ./price-a-number/example.sh 447700900123 sms
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

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || { [ "${2:-voice}" != voice ] && [ "${2:-voice}" != sms ]; }; then
  echo "Usage: price-a-number/example.sh <number> [voice|sms]" >&2
  exit 2
fi
number="$1"
type="${2:-voice}"
if [ -z "${PACKETEXCHANGE_API_KEY:-}" ]; then
  echo "Set PACKETEXCHANGE_API_KEY first (see .env.example)." >&2
  exit 2
fi
unit="$([ "$type" = sms ] && echo msg || echo min)"
encoded_number="$(jq -rn --arg n "$number" '$n | @uri')"

# Each route is priced for this exact number: the longest matching rate-sheet prefix,
# or the listing's flat price. ASR figures are stated by the seller, not measured.
px GET "/routes/price-number?number=$encoded_number&type=$type" | jq -r --arg number "$number" --arg type "$type" '
  .data
  | if .notice == "sanctioned" then "No routes: the destination is embargoed."
    else
      "\(.total) routes serve \($number) (\($type)), cheapest first:",
      (.unit as $unit | .routes[:5][]
        | "  \(.rate)/\($unit)  \(.destination)  prefix \(.matchedPrefix)  "
          + (if .expectedAsr == null then "ASR n/a" else "ASR \(.expectedAsr)% (seller-stated)" end)
          + "  \(.id)")
    end'

# Resolve runs as your account, so it also sees private routes you have bought.
for strategy in cheapest best_quality balanced; do
  px GET "/routes/resolve?to=$encoded_number&type=$type&strategy=$strategy" \
    | jq -r --arg s "$strategy" --arg unit "$unit" '.data.selected
      | if . then "Strategy \($s): \(.price)/\($unit) via \(.id) (\(.destinationName))"
        else "Strategy \($s): no route" end'
done
