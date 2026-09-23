# shellcheck shell=bash
# Helpers shared by every <language>/run-examples.sh. Source it, do not execute it.

failures=0

# expect_exit <code> <command...>
# Runs the command (stdin is passed through), prints its output, and records a failure
# when the exit code differs from the expected one.
expect_exit() {
  local want="$1"
  shift
  local got=0
  echo "\$ $*"
  "$@" || got=$?
  if [ "$got" -eq "$want" ]; then
    echo "  -> exit $got (expected)"
  else
    echo "  -> FAIL: exit $got, expected $want"
    failures=$((failures + 1))
  fi
  echo
}

# expect_output <code> <text> <command...>
# Like expect_exit, and also requires <text> to appear in the combined stdout and stderr.
expect_output() {
  local want_code="$1" want_text="$2"
  shift 2
  local out got=0
  echo "\$ $*"
  out="$("$@" 2>&1)" || got=$?
  printf '%s\n' "$out"
  if [ "$got" -ne "$want_code" ]; then
    echo "  -> FAIL: exit $got, expected $want_code"
    failures=$((failures + 1))
  elif ! printf '%s' "$out" | grep -qF -- "$want_text"; then
    echo "  -> FAIL: \"$want_text\" not in output"
    failures=$((failures + 1))
  else
    echo "  -> exit $got with \"$want_text\" (expected)"
  fi
  echo
}

# require_free_port <port>: fails fast when something else already listens on the port,
# so a test never talks to a stale server left over from another run.
require_free_port() {
  if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then
    echo "Port $1 is already in use; set WEBHOOK_PORT to a free port" >&2
    return 1
  fi
}

# wait_for_port <port>: waits up to 10 seconds for a local TCP port to accept connections.
wait_for_port() {
  for _ in $(seq 1 50); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; then
      return 0
    fi
    sleep 0.2
  done
  echo "Nothing listening on port $1" >&2
  return 1
}

# finish: prints a summary and exits non-zero if any case failed.
finish() {
  if [ "$failures" -gt 0 ]; then
    echo "$failures case(s) failed"
    exit 1
  fi
  echo "All cases passed"
}
