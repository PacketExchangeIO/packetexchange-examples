"""Place one outbound call and read its outcome and cost, then find its ledger entry.

POST /comms/calls returns when the call has ended, so the client waits for it.

    python make-call/main.py +14155550100 +14155550199 60
"""

import os
import sys
import uuid
from typing import Any, NoReturn

import httpx

BASE_URL = os.environ.get("PACKETEXCHANGE_BASE_URL", "https://packetexchange.io/api/v1").removesuffix("/")
API_KEY = os.environ.get("PACKETEXCHANGE_API_KEY")


def api(method: str, path: str, body: Any = None, headers: dict[str, str] | None = None, timeout: float = 30.0) -> Any:
    """Sends one API request and returns the parsed JSON body. Any non-2xx response ends the program."""
    try:
        res = httpx.request(
            method,
            f"{BASE_URL}{path}",
            json=body,
            headers={
                "Authorization": f"Bearer {API_KEY}",
                "Content-Type": "application/json",
                "Accept": "application/json",
                **(headers or {}),
            },
            timeout=timeout,
        )
    except httpx.HTTPError as err:
        sys.exit(f"Network error: {err}")
    if not res.is_success:
        exit_with_api_error(res)
    return res.json()


def exit_with_api_error(res: httpx.Response) -> NoReturn:
    """Prints the API error envelope (code, message, field details, request id) and exits with 1."""
    try:
        parsed = res.json()
    except ValueError:
        parsed = None  # Not JSON, for example an HTML error page from a proxy.
    error = parsed.get("error") if isinstance(parsed, dict) else None
    if isinstance(error, dict) and error.get("code"):
        print(f"Error {res.status_code} {error['code']}: {error.get('message')}", file=sys.stderr)
        details = error.get("details")
        for d in details if isinstance(details, list) else []:
            print(f"  - {d.get('path')}: {d.get('message')}", file=sys.stderr)
    else:
        print(f"Error {res.status_code}: {res.text[:200]}", file=sys.stderr)
    retry_after = res.headers.get("retry-after")
    if res.status_code == 429 and retry_after:
        print(f"Retry after: {retry_after} seconds", file=sys.stderr)
    request_id = res.headers.get("x-request-id")
    if request_id:
        print(f"Request id: {request_id}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    if len(sys.argv) not in (3, 4) or (len(sys.argv) == 4 and not sys.argv[3].isdigit()):
        print("Usage: python make-call/main.py <to> <caller-id> [max-duration-seconds]", file=sys.stderr)
        sys.exit(2)
    to, caller_id = sys.argv[1], sys.argv[2]
    max_duration = int(sys.argv[3]) if len(sys.argv) == 4 else 60
    if not API_KEY:
        print("Set PACKETEXCHANGE_API_KEY first (see .env.example).", file=sys.stderr)
        sys.exit(2)

    # The request stays open until the call is answered and hung up, not answered, or
    # reaches maxDuration, so the client timeout must be longer than maxDuration.
    call = api(
        "POST",
        "/comms/calls",
        {"to": to, "from": caller_id, "maxDuration": max_duration},
        {"X-Idempotency-Key": str(uuid.uuid4())},
        timeout=max_duration + 30,
    )["data"]
    print(f"Call finished: {call['callId']}")
    print(f"  status: {call['status']}")
    print(f"  durationSeconds: {call['durationSeconds']}")
    print(f"  billableSeconds: {call['billableSeconds']}")
    print(f"  cost: {call['cost']}")
    print(f"  hangupCause: {call['hangupCause'] or 'none'}")

    # Call history is the account ledger, newest first; the entry references the call id.
    entries = api("GET", "/comms/calls?limit=25")["data"]
    entry = next((e for e in entries if call["callId"] in (e.get("relatedEntityId"), e.get("callId"))), None)
    if entry:
        print(f"Ledger entry: {entry['amount']} (balance after {entry['balanceAfter']})")
    else:
        print("Ledger entry: not in the latest 25 entries")


if __name__ == "__main__":
    main()
