// Call a customer to confirm an appointment: the answered call speaks a message, asks
// for one key press, and the program follows the call until it ends.
//
//   node call-with-actions/index.ts +14155550100 +14155550199

import { randomUUID } from 'node:crypto';
import { setTimeout as sleep } from 'node:timers/promises';

const BASE_URL = (process.env.PACKETEXCHANGE_BASE_URL ?? 'https://packetexchange.io/api/v1').replace(/\/$/, '');
const API_KEY = process.env.PACKETEXCHANGE_API_KEY;

interface ApiErrorBody {
  error?: { code?: string; message?: string; details?: { path: string; message: string }[] };
}

interface PlacedCall {
  callId: string;
  status: string;
}

interface CallStatus {
  callId: string;
  status: string;
  durationSeconds: number | null;
  cost: string | null;
  hangupReason: string | null;
  gathered: { index: number; digits: string | null; status: string }[] | null;
}

// What the answered call does, in order. The call hangs up after the last action.
const ACTIONS = [
  { say: 'Hello, this is Riverside Clinic calling about your appointment tomorrow at 10:30.' },
  { gather: { digits: 1, timeout: 5, say: 'Press 1 to confirm, or 2 if you need to reschedule.' } },
  { say: 'Thank you. Goodbye.' },
];

const FINAL = new Set(['completed', 'no_answer', 'busy', 'failed']);
const POLL_EVERY_MS = 2_000;
const GIVE_UP_AFTER_MS = 5 * 60_000;

/** Sends one API request and returns the parsed JSON body. Any non-2xx response ends the program. */
async function api<T>(method: string, path: string, body?: unknown, headers: Record<string, string> = {}): Promise<T> {
  let res: Response;
  try {
    res = await fetch(`${BASE_URL}${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${API_KEY}`,
        'Content-Type': 'application/json',
        Accept: 'application/json',
        ...headers,
      },
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(30_000),
    });
  } catch (err) {
    console.error(`Network error: ${(err as Error).message}`);
    process.exit(1);
  }
  const text = await res.text();
  if (!res.ok) exitWithApiError(res, text);
  return JSON.parse(text) as T;
}

/** Prints the API error envelope (code, message, field details, request id) and exits with 1. */
function exitWithApiError(res: Response, text: string): never {
  let parsed: ApiErrorBody | undefined;
  try {
    parsed = JSON.parse(text) as ApiErrorBody;
  } catch {
    // Not JSON, for example an HTML error page from a proxy.
  }
  const error = parsed?.error;
  if (error?.code) {
    console.error(`Error ${res.status} ${error.code}: ${error.message}`);
    for (const d of Array.isArray(error.details) ? error.details : []) console.error(`  - ${d.path}: ${d.message}`);
  } else {
    console.error(`Error ${res.status}: ${text.slice(0, 200)}`);
  }
  const retryAfter = res.headers.get('retry-after');
  if (res.status === 429 && retryAfter) console.error(`Retry after: ${retryAfter} seconds`);
  const requestId = res.headers.get('x-request-id');
  if (requestId) console.error(`Request id: ${requestId}`);
  process.exit(1);
}

async function main(): Promise<void> {
  const [to, callerId] = process.argv.slice(2);
  if (!to || !callerId) {
    console.error('Usage: node call-with-actions/index.ts <to> <caller-id>');
    process.exit(2);
  }
  if (!API_KEY) {
    console.error('Set PACKETEXCHANGE_API_KEY first (see .env.example).');
    process.exit(2);
  }

  // async: true answers as soon as the number is being dialled (HTTP 202, status
  // ringing) instead of holding the request open until the call ends.
  const { data: placed } = await api<{ data: PlacedCall }>(
    'POST',
    '/comms/calls',
    { to, from: callerId, maxDuration: 120, async: true, language: 'en', actions: ACTIONS },
    { 'X-Idempotency-Key': randomUUID() },
  );
  console.log(`Call placed: ${placed.callId} (status ${placed.status})`);

  // Poll the call until it ends. In production, the call.answered, call.gathered and
  // call.completed webhooks tell you the same without polling.
  const deadline = Date.now() + GIVE_UP_AFTER_MS;
  let lastStatus = placed.status;
  for (;;) {
    const { data: call } = await api<{ data: CallStatus }>('GET', `/comms/calls/${encodeURIComponent(placed.callId)}`);
    if (call.status !== lastStatus) {
      console.log(`  status: ${call.status}`);
      lastStatus = call.status;
    }
    if (FINAL.has(call.status)) {
      // Gathered digits are filled in when the call ends.
      const pressed = call.gathered?.find((g) => g.index === 0)?.digits;
      console.log(`Call ended: ${call.status}`);
      console.log(`  durationSeconds: ${call.durationSeconds ?? 0}`);
      console.log(`  cost: ${call.cost ?? 'none'}`);
      console.log(`  hangupReason: ${call.hangupReason ?? 'none'}`);
      console.log(`  keyPressed: ${pressed ?? 'none'}`);
      return;
    }
    if (Date.now() + POLL_EVERY_MS > deadline) {
      console.log(`Still running after 5 minutes; check GET /comms/calls/${placed.callId} later.`);
      return;
    }
    await sleep(POLL_EVERY_MS);
  }
}

await main();
