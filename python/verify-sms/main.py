"""Send a one-time code by SMS with the Verify API, then check the code the user typed.

python verify-sms/main.py +14155550100
"""

import os
import sys
import uuid
from typing import Any, NoReturn

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
        print("Usage: python verify-sms/main.py <to>", file=sys.stderr)
        sys.exit(2)
    to = sys.argv[1]
    if not API_KEY:
        print("Set PACKETEXCHANGE_API_KEY first (see .env.example).", file=sys.stderr)
        sys.exit(2)

    # PacketExchange generates the code, sends it and stores only a hash of it. The
    # idempotency key makes a retried request safe: it cannot send a second code.
    started = api(
        "POST",
        "/verify/start",
        {"to": to, "channel": "sms"},
        {"X-Idempotency-Key": str(uuid.uuid4())},
    )["data"]
    print(f"Verification sent by SMS to {to}")
    print(f"  verificationId: {started['verificationId']}")
    print(f"  expiresAt: {started['expiresAt']}")
    # Only test keys return the code, because nothing is actually sent.
    if started.get("testCode"):
        print(f"  testCode: {started['testCode']}")

    code = input("Enter the code: ").strip()

    # A wrong code is a normal answer (status "denied"), not an HTTP error.
    result = api("POST", "/verify/check", {"verificationId": started["verificationId"], "code": code})["data"]
    reason = f" ({result['reason']})" if result.get("reason") else ""
    print(f"Check result: {result['status']}{reason}")
    print(f"  attemptsRemaining: {result['attemptsRemaining']}")


if __name__ == "__main__":
    main()
