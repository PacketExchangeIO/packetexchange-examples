"""A minimal webhook receiver that verifies PacketExchange signatures before trusting a delivery.

    PACKETEXCHANGE_WEBHOOK_SECRET=... python webhooks/main.py

Current scheme:  X-PX-Timestamp: <unix seconds>
                 X-PX-Signature: v1=<hex HMAC-SHA256(secret, "<timestamp>.<raw body>")>
Legacy scheme:   X-Webhook-Signature: sha256=<hex HMAC-SHA256(secret, <raw body>)>
"""

import hashlib
import hmac
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECRET = os.environ.get("PACKETEXCHANGE_WEBHOOK_SECRET", "")
PORT = int(os.environ.get("PORT", "3000"))
# Deliveries older (or newer) than this are refused, so a captured request cannot be replayed later.
TOLERANCE_SECONDS = 300


def hmac_hex(payload: bytes) -> str:
    return hmac.new(SECRET.encode(), payload, hashlib.sha256).hexdigest()


def verify(headers, raw_body: bytes) -> tuple[bool, str]:
    """Checks the signature over the exact bytes received, before the body is parsed.

    Returns (True, scheme) when the delivery is authentic, or (False, reason).
    """
    signature = headers.get("X-PX-Signature")
    if signature:
        timestamp = headers.get("X-PX-Timestamp", "")
        if not timestamp.isdigit():
            return False, "missing or malformed X-PX-Timestamp"
        if abs(time.time() - int(timestamp)) > TOLERANCE_SECONDS:
            return False, "timestamp outside the 5-minute window"
        expected = "v1=" + hmac_hex(timestamp.encode() + b"." + raw_body)
        # compare_digest takes the same time wherever the strings differ.
        if hmac.compare_digest(signature, expected):
            return True, "v1"
        return False, "invalid v1 signature"

    # Fallback for senders that only attach the legacy header. It proves who sent the body
    # but not when, so it cannot stop replays; prefer v1 whenever it is present.
    legacy = headers.get("X-Webhook-Signature")
    if legacy:
        if hmac.compare_digest(legacy, "sha256=" + hmac_hex(raw_body)):
            return True, "legacy"
        return False, "invalid legacy signature"
    return False, "no signature header"


class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self) -> None:
        if self.path != "/webhooks":
            self.send_response(404)
            self.end_headers()
            return
        raw_body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        ok, detail = verify(self.headers, raw_body)
        if not ok:
            print(f"Rejected delivery: {detail}", file=sys.stderr, flush=True)
            self.reply(401, "text/plain", detail.encode())
            return

        delivery = json.loads(raw_body)
        print(
            f"Received {delivery['event']} (delivery {self.headers.get('X-Webhook-Id')}, scheme {detail})", flush=True
        )
        # Answer quickly with a 2xx. Do slow work after responding, or queue it, so the
        # delivery is not timed out and retried.
        self.reply(200, "application/json", b'{"received":true}')

    def reply(self, status: int, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format: str, *args: object) -> None:
        pass  # Keep the output to the lines printed above.


def main() -> None:
    if not SECRET:
        print("Set PACKETEXCHANGE_WEBHOOK_SECRET first (see .env.example).", file=sys.stderr)
        sys.exit(2)
    server = ThreadingHTTPServer(("", PORT), WebhookHandler)
    print(f"Listening on http://localhost:{PORT}/webhooks", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
