"""Rank every marketplace route for one phone number by what it would really cost, then
show which route Smart Routing would pick for each strategy.

    python price-a-number/main.py +447700900123
    python price-a-number/main.py 447700900123 sms
"""

import os
import sys
from typing import Any, NoReturn
from urllib.parse import urlencode

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


STRATEGIES = ("cheapest", "best_quality", "balanced")


def main() -> None:
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] not in ("voice", "sms")):
        print("Usage: python price-a-number/main.py <number> [voice|sms]", file=sys.stderr)
        sys.exit(2)
    number = sys.argv[1]
    kind = sys.argv[2] if len(sys.argv) == 3 else "voice"
    if not API_KEY:
        print("Set PACKETEXCHANGE_API_KEY first (see .env.example).", file=sys.stderr)
        sys.exit(2)
    unit = "msg" if kind == "sms" else "min"

    # Each route is priced for this exact number: the longest matching rate-sheet prefix,
    # or the listing's flat price. ASR figures are stated by the seller, not measured.
    priced = api("GET", f"/routes/price-number?{urlencode({'number': number, 'type': kind})}")["data"]
    if priced.get("notice") == "sanctioned":
        print("No routes: the destination is embargoed.")
    else:
        print(f"{priced['total']} routes serve {number} ({kind}), cheapest first:")
        for r in priced["routes"][:5]:
            asr = "ASR n/a" if r["expectedAsr"] is None else f"ASR {r['expectedAsr']}% (seller-stated)"
            print(f"  {r['rate']}/{priced['unit']}  {r['destination']}  prefix {r['matchedPrefix']}  {asr}  {r['id']}")

    # Resolve runs as your account, so it also sees private routes you have bought.
    for strategy in STRATEGIES:
        query = urlencode({"to": number, "type": kind, "strategy": strategy})
        selected = api("GET", f"/routes/resolve?{query}")["data"]["selected"]
        if selected:
            print(
                f"Strategy {strategy}: {selected['price']}/{unit} via {selected['id']} ({selected['destinationName']})"
            )
        else:
            print(f"Strategy {strategy}: no route")


if __name__ == "__main__":
    main()
