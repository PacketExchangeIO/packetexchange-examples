// A minimal webhook receiver that verifies PacketExchange signatures before trusting a delivery.
//
//   PACKETEXCHANGE_WEBHOOK_SECRET=... node webhooks/index.ts
//
// Current scheme:  X-PX-Timestamp: <unix seconds>
//                  X-PX-Signature: v1=<hex HMAC-SHA256(secret, "<timestamp>.<raw body>")>
// Legacy scheme:   X-Webhook-Signature: sha256=<hex HMAC-SHA256(secret, <raw body>)>

import { createHmac, timingSafeEqual } from 'node:crypto';
import { createServer, type IncomingMessage } from 'node:http';

const SECRET = process.env.PACKETEXCHANGE_WEBHOOK_SECRET;
const PORT = Number(process.env.PORT ?? 3000);
// Deliveries older (or newer) than this are refused, so a captured request cannot be replayed later.
const TOLERANCE_SECONDS = 300;

interface Delivery {
  event: string;
  data: unknown;
  timestamp: string;
}

type Verdict = { ok: true; scheme: 'v1' | 'legacy' } | { ok: false; reason: string };

function hmacHex(payload: string | Buffer): string {
  return createHmac('sha256', SECRET as string).update(payload).digest('hex');
}

/** Constant-time comparison, so response timing reveals nothing about the expected value. */
function safeEqual(a: string, b: string): boolean {
  const left = Buffer.from(a);
  const right = Buffer.from(b);
  return left.length === right.length && timingSafeEqual(left, right);
}

function header(req: IncomingMessage, name: string): string | undefined {
  const value = req.headers[name];
  return Array.isArray(value) ? value[0] : value;
}

/** Checks the signature over the exact bytes received, before the body is parsed. */
function verify(req: IncomingMessage, rawBody: Buffer): Verdict {
  const signature = header(req, 'x-px-signature');
  if (signature) {
    const timestamp = header(req, 'x-px-timestamp');
    if (!timestamp || !/^\d+$/.test(timestamp)) return { ok: false, reason: 'missing or malformed X-PX-Timestamp' };
    if (Math.abs(Date.now() / 1000 - Number(timestamp)) > TOLERANCE_SECONDS) {
      return { ok: false, reason: 'timestamp outside the 5-minute window' };
    }
    const expected = `v1=${hmacHex(Buffer.concat([Buffer.from(`${timestamp}.`), rawBody]))}`;
    return safeEqual(signature, expected) ? { ok: true, scheme: 'v1' } : { ok: false, reason: 'invalid v1 signature' };
  }

  // Fallback for senders that only attach the legacy header. It proves who sent the body
  // but not when, so it cannot stop replays; prefer v1 whenever it is present.
  const legacy = header(req, 'x-webhook-signature');
  if (legacy) {
    return safeEqual(legacy, `sha256=${hmacHex(rawBody)}`)
      ? { ok: true, scheme: 'legacy' }
      : { ok: false, reason: 'invalid legacy signature' };
  }
  return { ok: false, reason: 'no signature header' };
}

if (!SECRET) {
  console.error('Set PACKETEXCHANGE_WEBHOOK_SECRET first (see .env.example).');
  process.exit(2);
}

const server = createServer((req, res) => {
  if (req.method !== 'POST' || req.url !== '/webhooks') {
    res.writeHead(404).end();
    return;
  }
  const chunks: Buffer[] = [];
  req.on('data', (chunk: Buffer) => chunks.push(chunk));
  req.on('end', () => {
    const rawBody = Buffer.concat(chunks);
    const verdict = verify(req, rawBody);
    if (!verdict.ok) {
      console.error(`Rejected delivery: ${verdict.reason}`);
      res.writeHead(401, { 'Content-Type': 'text/plain' }).end(verdict.reason);
      return;
    }

    const delivery = JSON.parse(rawBody.toString('utf8')) as Delivery;
    console.log(`Received ${delivery.event} (delivery ${header(req, 'x-webhook-id')}, scheme ${verdict.scheme})`);
    // Answer quickly with a 2xx. Do slow work after responding, or queue it, so the
    // delivery is not timed out and retried.
    res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify({ received: true }));
  });
});

server.listen(PORT, () => {
  console.log(`Listening on http://localhost:${PORT}/webhooks`);
});
