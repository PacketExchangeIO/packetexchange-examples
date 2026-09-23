#!/usr/bin/env bash
# Search for a phone number, buy it, and point its calls at a SIP server or another number.
# Buying charges the setup price plus the first month, so it needs --confirm.
#
#   ./phone-numbers/example.sh search 1415
#   ./phone-numbers/example.sh buy <groupId> <skuId> --confirm
#   ./phone-numbers/example.sh route <didId> sip sip.example.com:5060
#   ./phone-numbers/example.sh route <didId> forward +14155550123
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

usage() {
  echo "Usage: phone-numbers/example.sh search [pattern]" >&2
  echo "       phone-numbers/example.sh buy <groupId> <skuId> --confirm" >&2
  echo "       phone-numbers/example.sh route <didId> sip|forward <target>" >&2
  exit 2
}

# While the number store is switched off, these endpoints answer 200 with { disabled, message }.
exit_if_store_disabled() {
  if jq -e '.data.disabled? // false' <<<"$1" >/dev/null; then
    jq -r '"Number store unavailable: \(.data.message)"' <<<"$1"
    exit 0
  fi
}

confirmed=false
args=()
for arg in "$@"; do
  if [ "$arg" = --confirm ]; then confirmed=true; else args+=("$arg"); fi
done
set -- "${args[@]+"${args[@]}"}"
if [ -z "${PACKETEXCHANGE_API_KEY:-}" ]; then
  echo "Set PACKETEXCHANGE_API_KEY first (see .env.example)." >&2
  exit 2
fi

case "${1:-} $#" in
  "search 1" | "search 2")
    query="limit=5"
    if [ "$#" -eq 2 ]; then query="$query&pattern=$(jq -rn --arg p "$2" '$p | @uri')"; fi
    # Search results are top-level fields of the body, not wrapped in `data`.
    body="$(px GET "/dids/search?$query")"
    exit_if_store_disabled "$body"
    # usd: a JSON number printed with 2 decimals (catalogue prices are numbers, not money strings).
    jq -r 'def usd: (. * 100 | round) as $c | "\($c / 100 | floor).\($c % 100 | tostring | if length < 2 then "0" + . else . end)";
      "\(.hits | length) number groups found:",
      (.hits[]
        | "  \(.dialingPrefix)  \(.country)\(if .city then ", \(.city)" else "" end)  \(.typeName // "")  groupId \(.groupId)",
          (.skus[] | "    skuId \(.skuId): setup $\(.setupPrice | usd), monthly $\(.monthlyPrice | usd), \(.channels) channels"))' <<<"$body"
    ;;
  "buy 3")
    if [ "$confirmed" != true ]; then
      echo "Buying a number charges the setup price plus the first month to your balance." >&2
      echo "Re-run with --confirm to place the order." >&2
      exit 2
    fi
    # This spends money. The idempotency key guarantees a retried request orders one number, not two.
    body="$(px POST /dids/buy "$(jq -nc --arg g "$2" --arg s "$3" '{groupId: $g, skuId: $s}')" \
      -H "X-Idempotency-Key: $(idempotency_key)")"
    exit_if_store_disabled "$body"
    # The number is assigned when provisioning completes; until then it is null.
    jq -r '.data | "Number ordered: \(.id)", "  status: \(.status)", "  number: \(.number // "pending")",
      "  setupPrice: \(.setupPrice)", "  monthlyPrice: \(.monthlyPrice)"' <<<"$body"
    ;;
  "route 4")
    if [ "$3" != sip ] && [ "$3" != forward ]; then usage; fi
    # sip: host[:port] of your SIP server. forward: an E.164 number to ring instead.
    body="$(px PATCH "/dids/$(jq -rn --arg id "$2" '$id | @uri')/routing" \
      "$(jq -nc --arg m "$3" --arg t "$4" '{mode: $m, target: $t}')")"
    exit_if_store_disabled "$body"
    jq -r '.data | "Number \(.id) now routes to \(.pointMode) \(.pointsTo)"' <<<"$body"
    ;;
  *)
    usage
    ;;
esac
