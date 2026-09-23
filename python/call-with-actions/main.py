"""Call a customer to confirm an appointment: the answered call speaks a message, asks for one
key press, and the program follows the call until it ends.

    python call-with-actions/main.py +14155550100 +14155550199
"""

import os
import sys
import time
import uuid
from typing import Any, NoReturn
from urllib.parse import quote

import httpx

BASE_URL = os.environ.get("PACKETEXCHANGE_BASE_URL", "https://packetexchange.io/api/v1").removesuffix("/")
API_KEY = os.environ.get("PACKETEXCHANGE_API_KEY")


def api(method: str, path: str, body: Any = None, headers: dict[str, str] | None = None) -> Any:
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
            timeout=30.0,
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


# What the answered call does, in order. The call hangs up after the last action.
ACTIONS = [
    {"say": "Hello, this is Riverside Clinic calling about your appointment tomorrow at 10:30."},
    {"gather": {"digits": 1, "timeout": 5, "say": "Press 1 to confirm, or 2 if you need to reschedule."}},
    {"say": "Thank you. Goodbye."},
]

FINAL = {"completed", "no_answer", "busy", "failed"}
POLL_EVERY_SECONDS = 2
GIVE_UP_AFTER_SECONDS = 5 * 60


def main() -> None:
    if len(sys.argv) != 3:
        print("Usage: python call-with-actions/main.py <to> <caller-id>", file=sys.stderr)
        sys.exit(2)
    to, caller_id = sys.argv[1:3]
    if not API_KEY:
        print("Set PACKETEXCHANGE_API_KEY first (see .env.example).", file=sys.stderr)
        sys.exit(2)

    # async: true answers as soon as the number is being dialled (HTTP 202, status
    # ringing) instead of holding the request open until the call ends.
    placed = api(
        "POST",
        "/comms/calls",
        {"to": to, "from": caller_id, "maxDuration": 120, "async": True, "language": "en", "actions": ACTIONS},
        {"X-Idempotency-Key": str(uuid.uuid4())},
    )["data"]
    print(f"Call placed: {placed['callId']} (status {placed['status']})")

    # Poll the call until it ends. In production, the call.answered, call.gathered and
    # call.completed webhooks tell you the same without polling.
    deadline = time.monotonic() + GIVE_UP_AFTER_SECONDS
    last_status = placed["status"]
    while True:
        call = api("GET", f"/comms/calls/{quote(placed['callId'], safe='')}")["data"]
        if call["status"] != last_status:
            print(f"  status: {call['status']}")
            last_status = call["status"]
        if call["status"] in FINAL:
            # Gathered digits are filled in when the call ends.
            pressed = next((g["digits"] for g in call["gathered"] or [] if g["index"] == 0), None)
            print(f"Call ended: {call['status']}")
            print(f"  durationSeconds: {call['durationSeconds'] or 0}")
            print(f"  cost: {call['cost'] or 'none'}")
            print(f"  hangupReason: {call['hangupReason'] or 'none'}")
            print(f"  keyPressed: {pressed or 'none'}")
            return
        if time.monotonic() + POLL_EVERY_SECONDS > deadline:
            print(f"Still running after 5 minutes; check GET /comms/calls/{placed['callId']} later.")
            return
        time.sleep(POLL_EVERY_SECONDS)


if __name__ == "__main__":
    main()
