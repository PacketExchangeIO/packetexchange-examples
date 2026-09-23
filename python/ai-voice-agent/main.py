"""Create an AI voice agent, try one conversation turn in text, and optionally attach it
to a voice campaign so it handles the answered calls.

    python ai-voice-agent/main.py
    python ai-voice-agent/main.py <campaignId>
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


# The agent's script. A confirmation call to someone who booked an appointment is a
# transactional, expected call; keep agents to calls the recipient has agreed to receive.
AGENT = {
    "name": "Appointment confirmation",
    "language": "en",
    "firstMessage": (
        "Hello, this is Riverside Clinic calling to confirm your appointment tomorrow at 10:30. Can you still make it?"
    ),
    "systemPrompt": " ".join(
        [
            "You confirm appointments for Riverside Clinic.",
            "Ask whether the person can attend their appointment tomorrow at 10:30.",
            "If they can, thank them and end the call.",
            "If they cannot, offer to have the clinic call them back to reschedule.",
            "Keep every reply short and polite.",
        ]
    ),
    "guardrails": (
        "Never ask for payment details, passwords or medical information. "
        "If the person asks to stop receiving calls, confirm and end the call."
    ),
    "maxCallSeconds": 180,
}


def main() -> None:
    if len(sys.argv) > 2:
        print("Usage: python ai-voice-agent/main.py [campaign-id]", file=sys.stderr)
        sys.exit(2)
    campaign_id = sys.argv[1] if len(sys.argv) == 2 else None
    if not API_KEY:
        print("Set PACKETEXCHANGE_API_KEY first (see .env.example).", file=sys.stderr)
        sys.exit(2)

    # Prefer a standard English voice; premium voices are listed too.
    voices = api("GET", "/ai-agents/voices")["data"]
    voice = next((v for v in voices if v["language"] == "en" and not v["is_pro"]), voices[0] if voices else None)
    if voice is None:
        sys.exit("No voices are available right now.")
    print(f"Using voice: {voice['name']} ({voice['id']})")

    agent = api("POST", "/ai-agents", {**AGENT, "voiceId": voice["id"]})["data"]
    print(f"Agent created: {agent['id']}")

    # Simulating a turn places no call and is not billed.
    turn = api("POST", f"/ai-agents/{agent['id']}/simulate", {"message": "Yes, I can still make it."})["data"]
    print(f"Simulated reply: {turn['reply']}")
    print(f"  action: {turn['action']}")

    # Agents run on outbound voice campaigns. The campaign must be a draft, ready or paused.
    if campaign_id:
        api("PUT", f"/dialer/campaigns/{quote(campaign_id, safe='')}", {"aiAgentId": agent["id"]})
        print(f"Attached agent to campaign {campaign_id}")


if __name__ == "__main__":
    main()
