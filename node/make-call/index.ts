// Place one outbound call and read its outcome and cost, then find its ledger entry.
// POST /comms/calls returns when the call has ended, so the client waits for it.
//
//   node make-call/index.ts +14155550100 +14155550199 60

import { randomUUID } from 'node:crypto';

const BASE_URL = (process.env.PACKETEXCHANGE_BASE_URL ?? 'https://packetexchange.io/api/v1').replace(/\/$/, '');
const API_KEY = process.env.PACKETEXCHANGE_API_KEY;

interface ApiErrorBody {
  error?: { code?: string; message?: string; details?: { path: string; message: string }[] };
}

interface CallResult {
  callId: string;
  status: string;
  durationSeconds: number;
  billableSeconds: number;
  cost: string;
  hangupCause: string | null;
}

interface LedgerEntry {
  amount: string;
  balanceAfter: string;
  relatedEntityId: string | null;
  callId: string | null;
}

/** Sends one API request and returns the parsed JSON body. Any non-2xx response ends the program. */
async function api<T>(method: string, path: string, body?: unknown, headers: Record<string, string> = {}, timeoutMs = 30_000): Promise<T> {
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
      signal: AbortSignal.timeout(timeoutMs),
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
  const [to, callerId, maxDurationArg = '60'] = process.argv.slice(2);
  const maxDuration = Number(maxDurationArg);
  if (!to || !callerId || !Number.isInteger(maxDuration)) {
    console.error('Usage: node make-call/index.ts <to> <caller-id> [max-duration-seconds]');
    process.exit(2);
  }
  if (!API_KEY) {
    console.error('Set PACKETEXCHANGE_API_KEY first (see .env.example).');
    process.exit(2);
  }

  // The request stays open until the call is answered and hung up, not answered, or
  // reaches maxDuration, so the client timeout must be longer than maxDuration.
  const { data: call } = await api<{ data: CallResult }>(
    'POST',
    '/comms/calls',
    { to, from: callerId, maxDuration },
    { 'X-Idempotency-Key': randomUUID() },
    (maxDuration + 30) * 1000,
  );
  console.log(`Call finished: ${call.callId}`);
  console.log(`  status: ${call.status}`);
  console.log(`  durationSeconds: ${call.durationSeconds}`);
  console.log(`  billableSeconds: ${call.billableSeconds}`);
  console.log(`  cost: ${call.cost}`);
  console.log(`  hangupCause: ${call.hangupCause ?? 'none'}`);

  // Call history is the account ledger, newest first; the entry references the call id.
  const { data: entries } = await api<{ data: LedgerEntry[] }>('GET', '/comms/calls?limit=25');
  const entry = entries.find((e) => e.relatedEntityId === call.callId || e.callId === call.callId);
  console.log(entry ? `Ledger entry: ${entry.amount} (balance after ${entry.balanceAfter})` : 'Ledger entry: not in the latest 25 entries');
}

await main();
