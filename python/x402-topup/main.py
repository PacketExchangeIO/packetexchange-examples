"""Top up your PacketExchange balance with USDC on Base using the x402 payment protocol.

THIS MOVES REAL FUNDS from the wallet in X402_PRIVATE_KEY, so the payment step needs --confirm.

    python x402-topup/main.py 25            shows what would be paid, pays nothing
    python x402-topup/main.py 25 --confirm  signs and pays

The exchange: POST without X-PAYMENT -> HTTP 402 with the payment requirements; sign an
EIP-3009 USDC transferWithAuthorization for exactly those requirements; POST again with it
base64-encoded in X-PAYMENT. The platform settles it on-chain and credits the balance.
"""

import base64
import json
import os
import re
import secrets
import sys
import time
from typing import Any, NoReturn

import httpx
from eth_account import Account

BASE_URL = os.environ.get("PACKETEXCHANGE_BASE_URL", "https://packetexchange.io/api/v1").removesuffix("/")
API_KEY = os.environ.get("PACKETEXCHANGE_API_KEY")
PRIVATE_KEY = os.environ.get("X402_PRIVATE_KEY", "")

# The only token and networks this example will pay on. Checking them stops a wrong or
# tampered challenge from making you sign for a different asset or chain.
NETWORKS = {
    "base": {"chain_id": 8453, "usdc": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"},
    "base-sepolia": {"chain_id": 84532, "usdc": "0x036CbD53842c5426634e7929541eC2318f3dCF7e"},
}


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


def post_topup(amount_usd: float, payment: str | None = None) -> httpx.Response:
    """POSTs the top-up. A 402 is part of the protocol here, so it is returned instead of treated as an error."""
    headers = {"Authorization": f"Bearer {API_KEY}", "Accept": "application/json"}
    if payment:
        headers["X-PAYMENT"] = payment
    try:
        # Settlement waits for the on-chain transfer, so allow longer than a normal call.
        res = httpx.post(f"{BASE_URL}/topups/x402", json={"amountUsd": amount_usd}, headers=headers, timeout=120.0)
    except httpx.HTTPError as err:
        sys.exit(f"Network error: {err}")
    if not res.is_success and res.status_code != 402:
        exit_with_api_error(res)
    return res


def check_requirements(reqs: dict[str, Any] | None, amount_usd: float) -> dict[str, Any]:
    """Refuses to sign unless the challenge asks for exactly the amount, token and chain expected."""
    expected_atomic = str(round(amount_usd * 1_000_000))  # USDC has 6 decimals
    network = NETWORKS.get(reqs["network"]) if reqs else None
    if not reqs:
        problem = "the 402 response has no payment requirements"
    elif reqs["scheme"] != "exact":
        problem = f'unsupported scheme "{reqs["scheme"]}"'
    elif not network:
        problem = f'unsupported network "{reqs["network"]}"'
    elif reqs["asset"].lower() != network["usdc"].lower():
        problem = f"asset {reqs['asset']} is not USDC on {reqs['network']}"
    elif reqs["maxAmountRequired"] != expected_atomic:
        problem = f"amount {reqs['maxAmountRequired']} does not match {expected_atomic}"
    else:
        return reqs
    sys.exit(f"Refusing to pay: {problem}.")


def build_payment(reqs: dict[str, Any], private_key: str) -> str:
    """Signs an EIP-3009 transferWithAuthorization and encodes it as the X-PAYMENT header value."""
    account = Account.from_key(private_key)
    now = int(time.time())
    nonce = secrets.token_bytes(32)  # a fresh random nonce makes the authorization single-use on-chain
    authorization = {
        "from": account.address,
        "to": reqs["payTo"],
        "value": reqs["maxAmountRequired"],
        # A little clock-skew allowance before, and the challenge's own timeout after.
        "validAfter": str(now - 600),
        "validBefore": str(now + reqs["maxTimeoutSeconds"]),
        "nonce": "0x" + nonce.hex(),
    }
    typed_data = {
        "types": {
            "EIP712Domain": [
                {"name": "name", "type": "string"},
                {"name": "version", "type": "string"},
                {"name": "chainId", "type": "uint256"},
                {"name": "verifyingContract", "type": "address"},
            ],
            "TransferWithAuthorization": [
                {"name": "from", "type": "address"},
                {"name": "to", "type": "address"},
                {"name": "value", "type": "uint256"},
                {"name": "validAfter", "type": "uint256"},
                {"name": "validBefore", "type": "uint256"},
                {"name": "nonce", "type": "bytes32"},
            ],
        },
        "primaryType": "TransferWithAuthorization",
        "domain": {
            "name": reqs["extra"]["name"],
            "version": reqs["extra"]["version"],
            "chainId": NETWORKS[reqs["network"]]["chain_id"],
            "verifyingContract": reqs["asset"],
        },
        "message": {
            **authorization,
            "value": int(authorization["value"]),
            "validAfter": int(authorization["validAfter"]),
            "validBefore": int(authorization["validBefore"]),
            "nonce": nonce,
        },
    }
    signed = Account.sign_typed_data(private_key, full_message=typed_data)
    payment = {
        "x402Version": 1,
        "scheme": reqs["scheme"],
        "network": reqs["network"],
        "payload": {"signature": "0x" + bytes(signed.signature).hex(), "authorization": authorization},
    }
    return base64.b64encode(json.dumps(payment).encode()).decode()


def main() -> None:
    confirmed = "--confirm" in sys.argv[1:]
    args = [a for a in sys.argv[1:] if a != "--confirm"]
    try:
        amount_usd = float(args[0]) if len(args) == 1 else 0.0
    except ValueError:
        amount_usd = 0.0
    if amount_usd <= 0:
        print("Usage: python x402-topup/main.py <amount-usd> [--confirm]", file=sys.stderr)
        sys.exit(2)
    if not API_KEY:
        print("Set PACKETEXCHANGE_API_KEY first (see .env.example).", file=sys.stderr)
        sys.exit(2)
    if not re.fullmatch(r"0x[0-9a-fA-F]{64}", PRIVATE_KEY):
        print(
            "Set X402_PRIVATE_KEY first (see .env.example): the 0x-prefixed private key of the paying wallet.",
            file=sys.stderr,
        )
        sys.exit(2)
    # Send whole dollars as an integer so the JSON matches what was typed (25, not 25.0).
    amount: float = int(amount_usd) if amount_usd.is_integer() else amount_usd

    # Step 1: ask what to pay. This request moves no money.
    first = post_topup(amount)
    if first.status_code == 201:
        print(f"x402 top-ups are not enabled: {first.json()['data'].get('message')}")
        return
    accepts = first.json().get("accepts") or [None]
    reqs = check_requirements(accepts[0], amount_usd)
    print(f"Payment required: {args[0]} USDC on {reqs['network']} to {reqs['payTo']}")

    if not confirmed:
        print("Re-run with --confirm to sign and send this payment.", file=sys.stderr)
        sys.exit(2)

    # Step 2: sign for exactly these requirements and send the same request again.
    second = post_topup(amount, build_payment(reqs, PRIVATE_KEY))
    if second.status_code == 402:
        sys.exit(f"Payment not accepted: {second.json().get('error')}")
    topup = second.json()["data"]
    print(f"Top-up confirmed: {topup['topupId']}")
    print(f"  txHash: {topup.get('txHash')}")
    print(f"  newBalance: {topup.get('newBalance')}")


if __name__ == "__main__":
    main()
