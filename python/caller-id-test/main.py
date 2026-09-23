"""Test which caller ID a route really delivers: a test handset in the destination country
receives a call and reports the number it displayed.

    python caller-id-test/main.py <routeId> +14155550199 "United States"
"""

import os
import sys
import time
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


FINAL = {"completed", "failed", "not_tested", "cancelled"}
POLL_EVERY_SECONDS = 10
GIVE_UP_AFTER_SECONDS = 10 * 60


def main() -> None:
    if len(sys.argv) != 4:
        print("Usage: python caller-id-test/main.py <route-id> <caller-id> <country>", file=sys.stderr)
        sys.exit(2)
    route_id, caller_id, country = sys.argv[1:4]
    if not API_KEY:
        print("Set PACKETEXCHANGE_API_KEY first (see .env.example).", file=sys.stderr)
        sys.exit(2)

    # Each test is a real call. It is charged only if the route rang; the live price is in the quota.
    quota = api("GET", "/cli-tests/quota")["data"]
    print(
        f"Caller-ID test price: ${quota['costPerTest']:.2f} per test, charged only if the route rang "
        f"({quota['remaining']} of {quota['limitPerHour']} left this hour)"
    )

    # The country must be the route's own destination country, for example "United Kingdom".
    created = api(
        "POST",
        "/cli-tests",
        {"routeId": route_id, "displayCli": caller_id, "testCountry": country},
    )["data"]
    print(f"Test queued: {created['id']} (status {created['status']})")

    deadline = time.monotonic() + GIVE_UP_AFTER_SECONDS
    last_status = created["status"]
    while True:
        test = api("GET", f"/cli-tests/{created['id']}")["data"]
        if test["status"] != last_status:
            print(f"  status: {test['status']}")
            last_status = test["status"]
        if test["status"] in FINAL:
            correct = test["displayedCorrectly"]
            print(f"Result: {test['status']}")
            print(f"  reportedCli: {test['reportedCli'] or 'none'}")
            print(f"  displayedCorrectly: {'unknown' if correct is None else str(correct).lower()}")
            print(f"  resultNotes: {test['resultNotes'] or 'none'}")
            return
        if time.monotonic() + POLL_EVERY_SECONDS > deadline:
            print(f"Still running after 10 minutes; check GET /cli-tests/{created['id']} later.")
            return
        time.sleep(POLL_EVERY_SECONDS)


if __name__ == "__main__":
    main()
