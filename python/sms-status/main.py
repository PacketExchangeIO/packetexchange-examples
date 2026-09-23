"""Read what happened to a message you sent: every step from queued to delivered or failed,
with timestamps. "delivered" only ever comes from a carrier receipt.

    python sms-status/main.py <messageId>
"""

import os
import sys
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


def main() -> None:
    if len(sys.argv) != 2:
        print("Usage: python sms-status/main.py <message-id>", file=sys.stderr)
        sys.exit(2)
    message_id = sys.argv[1]
    if not API_KEY:
        print("Set PACKETEXCHANGE_API_KEY first (see .env.example).", file=sys.stderr)
        sys.exit(2)

    sms = api("GET", f"/comms/sms/{quote(message_id, safe='')}")["data"]

    # An id that is not on your account answers 200 with status not_found.
    if sms["status"] == "not_found":
        print(f"No message {message_id} on this account.", file=sys.stderr)
        sys.exit(1)
    print(f"Message {sms['messageId']}: {sms['status']}")
    for step in sms.get("timeline") or []:
        extra = ", ".join(v for v in (step["source"], step.get("carrierStatus"), step.get("errorCode")) if v)
        print(f"  - {step['status']} at {step['at']} ({extra})")
    if sms.get("errorCode"):
        print(f"  errorCode: {sms['errorCode']}")
    # A route that returns no receipts leaves the message at "sent" for good.
    receipts = sms.get("routeReturnsReceipts")
    print(f"  awaitingReceipt: {str(sms.get('awaitingReceipt', False)).lower()}")
    print(f"  routeReturnsReceipts: {'unknown' if receipts is None else str(receipts).lower()}")


if __name__ == "__main__":
    main()
