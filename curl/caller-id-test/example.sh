#!/usr/bin/env bash
# Test which caller ID a route really delivers: a test handset in the destination
# country receives a call and reports the number it displayed.
#
#   ./caller-id-test/example.sh <routeId> +14155550199 "United States"
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

if [ "$#" -ne 3 ]; then
  echo "Usage: caller-id-test/example.sh <route-id> <caller-id> <country>" >&2
  exit 2
fi
route_id="$1"
caller_id="$2"
country="$3"
if [ -z "${PACKETEXCHANGE_API_KEY:-}" ]; then
  echo "Set PACKETEXCHANGE_API_KEY first (see .env.example)." >&2
  exit 2
fi

# Each test is a real call. It is charged only if the route rang; the live price is in the quota.
px GET /cli-tests/quota | jq -r '
  def usd: (. * 100 | round) as $c | "\($c / 100 | floor).\($c % 100 | tostring | if length < 2 then "0" + . else . end)";
  .data | "Caller-ID test price: $\(.costPerTest | usd) per test, charged only if the route rang (\(.remaining) of \(.limitPerHour) left this hour)"'

# The country must be the route's own destination country, for example "United Kingdom".
created="$(px POST /cli-tests "$(jq -nc --arg r "$route_id" --arg c "$caller_id" --arg country "$country" \
  '{routeId: $r, displayCli: $c, testCountry: $country}')")"
test_id="$(jq -r '.data.id' <<<"$created")"
last_status="$(jq -r '.data.status' <<<"$created")"
echo "Test queued: $test_id (status $last_status)"

deadline=$((SECONDS + 600))
while true; do
  test="$(px GET "/cli-tests/$test_id")"
  status="$(jq -r '.data.status' <<<"$test")"
  if [ "$status" != "$last_status" ]; then
    echo "  status: $status"
    last_status="$status"
  fi
  case "$status" in
    completed | failed | not_tested | cancelled)
      jq -r '.data | "Result: \(.status)", "  reportedCli: \(.reportedCli // "none")",
        "  displayedCorrectly: \(if .displayedCorrectly == null then "unknown" else .displayedCorrectly end)",
        "  resultNotes: \(.resultNotes // "none")"' <<<"$test"
      exit 0
      ;;
  esac
  if [ $((SECONDS + 10)) -gt "$deadline" ]; then
    echo "Still running after 10 minutes; check GET /cli-tests/$test_id later."
    exit 0
  fi
  sleep 10
done
