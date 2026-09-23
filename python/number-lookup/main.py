"""Look up a phone number before you message or call it: whether it is a valid E.164 number,
its country, line type and network, risk flags, and the cheapest live price.

    python number-lookup/main.py +447700900123
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


def price_line(label: str, price: dict[str, Any] | None) -> str:
    """One price line: the cheapest live route, or "no route" when none serves the number."""
    if not price:
        return f"  {label}: no route"
    serving = f"{price['routesServing']} routes serve it"
    return f"  {label}: {price['rate']}/{price['unit']} via {price['routeId']} ({serving})"


def main() -> None:
    if len(sys.argv) != 2:
        print("Usage: python number-lookup/main.py <number>", file=sys.stderr)
        sys.exit(2)
    number = sys.argv[1]
    if not API_KEY:
        print("Set PACKETEXCHANGE_API_KEY first (see .env.example).", file=sys.stderr)
        sys.exit(2)

    # Encode the number for use in the URL path, leading "+" included.
    data = api("GET", f"/lookup/{quote(number, safe='')}")["data"]

    # A malformed number is a normal answer (valid: false), not an HTTP error.
    if not data["valid"]:
        print(f"Not a valid number: {data['reason']}")
        return
    country = data["country"]
    network = data["network"]
    risk = data["risk"]
    print(f"{data['e164']} ({data['internationalFormat']})")
    where = f"{country['name']} ({country['iso'] or 'shared dial code'})" if country else "unknown"
    print(f"  country: {where}")
    print(f"  numberType: {data['numberType']}")
    # From number-range data: a ported number still shows the network its range belongs to.
    print(f"  network: {(network or {}).get('operator') or 'unknown'}")
    print(f"  risk: blocked {str(risk['blocked']).lower()}, highRisk {str(risk['highRisk']).lower()}")
    for reason in risk["reasons"]:
        print(f"    - {reason}")
    print(price_line("voice", data["pricing"]["voice"]))
    print(price_line("sms", data["pricing"]["sms"]))


if __name__ == "__main__":
    main()
