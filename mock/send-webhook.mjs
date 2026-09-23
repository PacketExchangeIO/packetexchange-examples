// Sends signed test deliveries to a webhook receiver and checks how it answers, so every
// language's `webhooks` example is tested the same way. Deliveries are built exactly as
// the PacketExchange dispatcher builds them: the JSON body `{ event, data, timestamp }`,
// `X-PX-Timestamp` + `X-PX-Signature: v1=<HMAC-SHA256(secret, "<timestamp>.<body>")>`,
// and the legacy `X-Webhook-Signature: sha256=<HMAC-SHA256(secret, body)>`.
//
//   node mock/send-webhook.mjs http://127.0.0.1:3100/webhooks
//   node mock/send-webhook.mjs --emit-dir <dir>     write one signed delivery to files
//
// The secret comes from PACKETEXCHANGE_WEBHOOK_SECRET.

import { createHmac, randomUUID } from 'node:crypto';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const secret = process.env.PACKETEXCHANGE_WEBHOOK_SECRET;
if (!secret) {
  console.error('Set PACKETEXCHANGE_WEBHOOK_SECRET first.');
  process.exit(2);
}

const hmac = (text) => createHmac('sha256', secret).update(text).digest('hex');

function delivery({ ageSeconds = 0 } = {}) {
  const body = JSON.stringify({
    event: 'sms.sent',
    data: { messageId: randomUUID(), to: '+14155550100', from: 'Riverside', status: 'accepted', segments: 1, cost: '0.006500' },
    timestamp: new Date().toISOString(),
  });
  const timestamp = String(Math.floor(Date.now() / 1000) - ageSeconds);
  return {
    body,
    headers: {
      'content-type': 'application/json',
      'X-Webhook-Event': 'sms.sent',
      'X-Webhook-Id': randomUUID(),
      'X-PX-Timestamp': timestamp,
      'X-PX-Signature': `v1=${hmac(`${timestamp}.${body}`)}`,
      'X-Webhook-Signature': `sha256=${hmac(body)}`,
    },
  };
}

const args = process.argv.slice(2);

if (args[0] === '--emit-dir') {
  const dir = args[1];
  if (!dir) {
    console.error('Usage: send-webhook.mjs --emit-dir <dir>');
    process.exit(2);
  }
  const d = delivery();
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'body.json'), d.body);
  writeFileSync(join(dir, 'timestamp'), d.headers['X-PX-Timestamp']);
  writeFileSync(join(dir, 'signature'), d.headers['X-PX-Signature']);
  writeFileSync(join(dir, 'legacy-signature'), d.headers['X-Webhook-Signature']);
  process.exit(0);
}

const url = args[0];
if (!url) {
  console.error('Usage: send-webhook.mjs <receiver-url> | --emit-dir <dir>');
  process.exit(2);
}

function without(headers, ...names) {
  return Object.fromEntries(Object.entries(headers).filter(([k]) => !names.includes(k)));
}

const cases = [
  { name: 'valid v1 signature', expect: 200, build: () => delivery() },
  {
    name: 'legacy signature only',
    expect: 200,
    build: () => {
      const d = delivery();
      return { ...d, headers: without(d.headers, 'X-PX-Timestamp', 'X-PX-Signature') };
    },
  },
  { name: 'timestamp 10 minutes old', expect: 401, build: () => delivery({ ageSeconds: 600 }) },
  {
    name: 'wrong v1 signature',
    expect: 401,
    build: () => {
      const d = delivery();
      return { ...d, headers: { ...d.headers, 'X-PX-Signature': `v1=${'0'.repeat(64)}` } };
    },
  },
  {
    name: 'body changed after signing',
    expect: 401,
    build: () => {
      const d = delivery();
      return { ...d, body: d.body.replace('0.006500', '0.000001') };
    },
  },
  {
    name: 'no signature headers',
    expect: 401,
    build: () => {
      const d = delivery();
      return { ...d, headers: without(d.headers, 'X-PX-Timestamp', 'X-PX-Signature', 'X-Webhook-Signature') };
    },
  },
];

let failures = 0;
for (const c of cases) {
  const d = c.build();
  let status;
  try {
    const res = await fetch(url, { method: 'POST', headers: d.headers, body: d.body });
    status = res.status;
  } catch (err) {
    status = `network error (${err.message})`;
  }
  const ok = status === c.expect;
  if (!ok) failures += 1;
  console.log(`${ok ? 'ok  ' : 'FAIL'} ${c.name}: got ${status}, expected ${c.expect}`);
}

process.exit(failures ? 1 : 0);
