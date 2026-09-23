#!/usr/bin/env bash
# Verify the signature of a PacketExchange webhook delivery from the command line, with
# openssl. curl cannot receive webhooks, so this checks one you have captured: the raw
# body saved to a file, plus the X-PX-Timestamp and X-PX-Signature header values.
#
#   ./webhooks/example.sh body.json 1767225600 v1=5f2c...
#   ./webhooks/example.sh --legacy body.json sha256=9ab1...
#
# Current scheme:  X-PX-Signature: v1=<hex HMAC-SHA256(secret, "<timestamp>.<raw body>")>
# Legacy scheme:   X-Webhook-Signature: sha256=<hex HMAC-SHA256(secret, <raw body>)>
set -euo pipefail

# Deliveries older (or newer) than this are refused, so a captured request cannot be replayed later.
tolerance_seconds=300

usage() {
  echo "Usage: webhooks/example.sh <body-file> <X-PX-Timestamp> <X-PX-Signature>" >&2
  echo "       webhooks/example.sh --legacy <body-file> <X-Webhook-Signature>" >&2
  exit 2
}

# hmac_hex: HMAC-SHA256 of stdin with the webhook secret, as lowercase hex. openssl takes the
# secret as an argument, so run this only on a machine you do not share with other users.
hmac_hex() {
  openssl dgst -sha256 -hmac "$PACKETEXCHANGE_WEBHOOK_SECRET" -r | cut -d' ' -f1
}

reject() {
  echo "Rejected delivery: $1" >&2
  exit 1
}

if [ -z "${PACKETEXCHANGE_WEBHOOK_SECRET:-}" ]; then
  echo "Set PACKETEXCHANGE_WEBHOOK_SECRET first (see .env.example)." >&2
  exit 2
fi

if [ "${1:-}" = --legacy ]; then
  [ "$#" -eq 3 ] || usage
  body_file="$2"
  # The legacy scheme proves who sent the body but not when, so it cannot stop replays.
  expected="sha256=$(hmac_hex <"$body_file")"
  # A plain comparison is fine here: this is an offline check, so nobody can time it. A
  # server must compare in constant time, as the other languages' receivers do.
  [ "$3" = "$expected" ] || reject "invalid legacy signature"
  scheme=legacy
else
  [ "$#" -eq 3 ] || usage
  body_file="$1"
  timestamp="$2"
  [[ "$timestamp" =~ ^[0-9]+$ ]] || reject "missing or malformed X-PX-Timestamp"
  age=$(($(date +%s) - timestamp))
  [ "${age#-}" -le "$tolerance_seconds" ] || reject "timestamp outside the 5-minute window"
  # Sign "<timestamp>." followed by the exact body bytes, with no added newline.
  expected="v1=$( { printf '%s.' "$timestamp"; cat "$body_file"; } | hmac_hex)"
  [ "$3" = "$expected" ] || reject "invalid v1 signature"
  scheme=v1
fi

echo "Signature valid (scheme $scheme): $(jq -r '.event' "$body_file")"
