"""Send one transactional SMS (an appointment reminder), then look up its status.

python send-sms/main.py +14155550100 Riverside
"""

import os
import sys
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


DEFAULT_MESSAGE = (
    "Reminder: your appointment at Riverside Clinic is tomorrow at 10:30. Call us if you need to reschedule."
)


def main() -> None:
    if len(sys.argv) not in (3, 4):
        print("Usage: python send-sms/main.py <to> <sender-id> [message]", file=sys.stderr)
        sys.exit(2)
    to, sender_id = sys.argv[1], sys.argv[2]
    message = sys.argv[3] if len(sys.argv) == 4 else DEFAULT_MESSAGE
    if not API_KEY:
        print("Set PACKETEXCHANGE_API_KEY first (see .env.example).", file=sys.stderr)
        sys.exit(2)

    # Smart Routing picks a route when routeId is omitted. The idempotency key makes a
    # retry safe: the same key never sends (or bills) the message twice.
    sent = api(
        "POST",
        "/comms/sms",
        {"to": to, "from": sender_id, "message": message},
        {"X-Idempotency-Key": str(uuid.uuid4())},
    )["data"]
    print(f"Message submitted: {sent['messageId']}")
    print(f"  status: {sent['status']}")
    print(f"  segments: {sent['segments']}")
    print(f"  cost: {sent['cost']}")

    # The status is the send-time outcome (accepted, sent or failed). Handset delivery
    # receipts are not collected, which `dlrSupported: false` states explicitly.
    status = api("GET", f"/comms/sms/{quote(sent['messageId'], safe='')}")["data"]
    print(f"Status lookup: {status['status']}")
    print(f"  dlrSupported: {str(status.get('dlrSupported', False)).lower()}")


if __name__ == "__main__":
    main()
