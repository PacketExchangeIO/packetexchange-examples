"""Search for a phone number, buy it, and point its calls at a SIP server or another number.

Buying charges the setup price plus the first month, so it needs --confirm.

    python phone-numbers/main.py search 1415
    python phone-numbers/main.py buy <groupId> <skuId> --confirm
    python phone-numbers/main.py route <didId> sip sip.example.com:5060
    python phone-numbers/main.py route <didId> forward +14155550123
"""

import os
import sys
import uuid
from typing import Any, NoReturn
from urllib.parse import quote, urlencode

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


USAGE = """Usage: python phone-numbers/main.py search [pattern]
       python phone-numbers/main.py buy <groupId> <skuId> --confirm
       python phone-numbers/main.py route <didId> sip|forward <target>"""


def exit_if_store_disabled(data: Any) -> None:
    # While the number store is switched off, these endpoints answer 200 with this shape.
    if isinstance(data, dict) and data.get("disabled"):
        print(f"Number store unavailable: {data.get('message')}")
        sys.exit(0)


def search(pattern: str | None) -> None:
    query = {"limit": "5"}
    if pattern:
        query["pattern"] = pattern
    # Search results are top-level fields of the body, not wrapped in `data`.
    body = api("GET", f"/dids/search?{urlencode(query)}")
    exit_if_store_disabled(body.get("data"))
    hits = body.get("hits", [])
    print(f"{len(hits)} number groups found:")
    for h in hits:
        place = f"{h['country']}, {h['city']}" if h.get("city") else h["country"]
        print(f"  {h['dialingPrefix']}  {place}  {h.get('typeName') or ''}  groupId {h['groupId']}")
        for s in h["skus"]:
            print(
                f"    skuId {s['skuId']}: setup ${s['setupPrice']:.2f}, "
                f"monthly ${s['monthlyPrice']:.2f}, {s['channels']} channels"
            )


def buy(group_id: str, sku_id: str, confirmed: bool) -> None:
    if not confirmed:
        print("Buying a number charges the setup price plus the first month to your balance.", file=sys.stderr)
        print("Re-run with --confirm to place the order.", file=sys.stderr)
        sys.exit(2)
    # This spends money. The idempotency key guarantees a retried request orders one number, not two.
    did = api(
        "POST",
        "/dids/buy",
        {"groupId": group_id, "skuId": sku_id},
        {"X-Idempotency-Key": str(uuid.uuid4())},
    )["data"]
    exit_if_store_disabled(did)
    print(f"Number ordered: {did['id']}")
    print(f"  status: {did['status']}")
    # The number is assigned when provisioning completes; until then it is null.
    print(f"  number: {did['number'] or 'pending'}")
    print(f"  setupPrice: {did['setupPrice']}")
    print(f"  monthlyPrice: {did['monthlyPrice']}")


def route(did_id: str, mode: str, target: str) -> None:
    # sip: host[:port] of your SIP server. forward: an E.164 number to ring instead.
    did = api("PATCH", f"/dids/{quote(did_id, safe='')}/routing", {"mode": mode, "target": target})["data"]
    exit_if_store_disabled(did)
    print(f"Number {did['id']} now routes to {did['pointMode']} {did['pointsTo']}")


def main() -> None:
    confirmed = "--confirm" in sys.argv[1:]
    args = [a for a in sys.argv[1:] if a != "--confirm"]
    if not API_KEY:
        print("Set PACKETEXCHANGE_API_KEY first (see .env.example).", file=sys.stderr)
        sys.exit(2)

    if args[:1] == ["search"] and len(args) <= 2:
        search(args[1] if len(args) == 2 else None)
    elif args[:1] == ["buy"] and len(args) == 3:
        buy(args[1], args[2], confirmed)
    elif args[:1] == ["route"] and len(args) == 4 and args[2] in ("sip", "forward"):
        route(args[1], args[2], args[3])
    else:
        print(USAGE, file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
