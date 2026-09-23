#!/usr/bin/env bash
# Look up a phone number before you message or call it: whether it is a valid E.164
# number, its country, line type and network, risk flags, and the cheapest live price.
#
#   ./number-lookup/example.sh +447700900123
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

if [ "$#" -ne 1 ]; then
  echo "Usage: number-lookup/example.sh <number>" >&2
  exit 2
fi
number="$1"
if [ -z "${PACKETEXCHANGE_API_KEY:-}" ]; then
  echo "Set PACKETEXCHANGE_API_KEY first (see .env.example)." >&2
  exit 2
fi

# Encode the number for use in the URL path, leading "+" included.
lookup="$(px GET "/lookup/$(jq -rn --arg n "$number" '$n | @uri')")"

# A malformed number is a normal answer (valid: false), not an HTTP error. The network
# comes from number-range data: a ported number still shows the network its range belongs to.
jq -r '
  def price($label): if . == null then "  \($label): no route"
    else "  \($label): \(.rate)/\(.unit) via \(.routeId) (\(.routesServing) routes serve it)" end;
  .data
  | if .valid | not then "Not a valid number: \(.reason)"
    else
      "\(.e164) (\(.internationalFormat))",
      "  country: \(if .country then "\(.country.name) (\(.country.iso // "shared dial code"))" else "unknown" end)",
      "  numberType: \(.numberType)",
      "  network: \(.network.operator // "unknown")",
      "  risk: blocked \(.risk.blocked), highRisk \(.risk.highRisk)",
      (.risk.reasons[] | "    - \(.)"),
      (.pricing.voice | price("voice")),
      (.pricing.sms | price("sms"))
    end' <<<"$lookup"
