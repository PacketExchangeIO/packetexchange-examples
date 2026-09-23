#!/usr/bin/env bash
# Starts the mock API, runs one command against it, then stops the mock.
#
#   scripts/with-mock.sh node/run-examples.sh
#
# The command inherits PACKETEXCHANGE_BASE_URL (pointing at the mock) and a placeholder
# test-style API key, so no real key or live endpoint is ever involved.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
port="${MOCK_PORT:-4010}"

if [ "$#" -eq 0 ]; then
  echo "Usage: scripts/with-mock.sh <command> [args...]" >&2
  exit 2
fi

# Refuse to run against something already listening there (for example a mock left over
# from another run), so results always come from the mock started below.
if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
  echo "Port $port is already in use; set MOCK_PORT to a free port" >&2
  exit 1
fi

MOCK_PORT="$port" node "$root/mock/server.mjs" >"${TMPDIR:-/tmp}/packetexchange-mock.log" 2>&1 &
mock_pid=$!
trap 'kill "$mock_pid" 2>/dev/null || true' EXIT

# Wait up to 10 seconds for the mock to answer its health check.
for _ in $(seq 1 50); do
  if curl -fsS "http://127.0.0.1:$port/api/v1/health" >/dev/null 2>&1; then
    break
  fi
  sleep 0.2
done
curl -fsS "http://127.0.0.1:$port/api/v1/health" >/dev/null

export PACKETEXCHANGE_BASE_URL="http://127.0.0.1:$port/api/v1"
export PACKETEXCHANGE_API_KEY="wmmn_test_sk_mock"
"$@"
