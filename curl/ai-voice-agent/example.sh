#!/usr/bin/env bash
# Create an AI voice agent, try one conversation turn in text, and optionally attach it
# to a voice campaign so it handles the answered calls.
#
#   ./ai-voice-agent/example.sh
#   ./ai-voice-agent/example.sh <campaignId>
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

if [ "$#" -gt 1 ]; then
  echo "Usage: ai-voice-agent/example.sh [campaign-id]" >&2
  exit 2
fi
campaign_id="${1:-}"
if [ -z "${PACKETEXCHANGE_API_KEY:-}" ]; then
  echo "Set PACKETEXCHANGE_API_KEY first (see .env.example)." >&2
  exit 2
fi

# Prefer a standard English voice; premium voices are listed too.
voice="$(px GET /ai-agents/voices | jq -c '.data as $v | ($v | map(select(.language == "en" and (.is_pro | not)))) + $v | .[0]')"
if [ "$voice" = null ]; then
  echo "No voices are available right now." >&2
  exit 1
fi
jq -r '"Using voice: \(.name) (\(.id))"' <<<"$voice"

# The agent's script. A confirmation call to someone who booked an appointment is a
# transactional, expected call; keep agents to calls the recipient has agreed to receive.
agent_body="$(jq -nc --arg voice "$(jq -r .id <<<"$voice")" '{
  name: "Appointment confirmation",
  voiceId: $voice,
  language: "en",
  firstMessage: "Hello, this is Riverside Clinic calling to confirm your appointment tomorrow at 10:30. Can you still make it?",
  systemPrompt: "You confirm appointments for Riverside Clinic. Ask whether the person can attend their appointment tomorrow at 10:30. If they can, thank them and end the call. If they cannot, offer to have the clinic call them back to reschedule. Keep every reply short and polite.",
  guardrails: "Never ask for payment details, passwords or medical information. If the person asks to stop receiving calls, confirm and end the call.",
  maxCallSeconds: 180
}')"
agent_id="$(px POST /ai-agents "$agent_body" | jq -r '.data.id')"
echo "Agent created: $agent_id"

# Simulating a turn places no call and is not billed.
px POST "/ai-agents/$agent_id/simulate" '{"message":"Yes, I can still make it."}' \
  | jq -r '.data | "Simulated reply: \(.reply)", "  action: \(.action)"'

# Agents run on outbound voice campaigns. The campaign must be a draft, ready or paused.
if [ -n "$campaign_id" ]; then
  px PUT "/dialer/campaigns/$(jq -rn --arg id "$campaign_id" '$id | @uri')" \
    "$(jq -nc --arg a "$agent_id" '{aiAgentId: $a}')" >/dev/null
  echo "Attached agent to campaign $campaign_id"
fi
