// Send one transactional SMS (an appointment reminder), then look up its status.
//
//   node send-sms/index.ts +14155550100 Riverside

import { randomUUID } from 'node:crypto';

const BASE_URL = (process.env.PACKETEXCHANGE_BASE_URL ?? 'https://packetexchange.io/api/v1').replace(/\/$/, '');
const API_KEY = process.env.PACKETEXCHANGE_API_KEY;

interface ApiErrorBody {
  error?: { code?: string; message?: string; details?: { path: string; message: string }[] };
}

interface SentSms {
  messageId: string;
  status: string;
  segments: number;
  cost: string;
}

interface SmsStatus {
  status: string;
  dlrSupported?: boolean;
}

const DEFAULT_MESSAGE =
  'Reminder: your appointment at Riverside Clinic is tomorrow at 10:30. Call us if you need to reschedule.';

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
  const [to, senderId, message = DEFAULT_MESSAGE] = process.argv.slice(2);
  if (!to || !senderId) {
    console.error('Usage: node send-sms/index.ts <to> <sender-id> [message]');
    process.exit(2);
  }
  if (!API_KEY) {
    console.error('Set PACKETEXCHANGE_API_KEY first (see .env.example).');
    process.exit(2);
  }

  // Smart Routing picks a route when routeId is omitted. The idempotency key makes a
  // retry safe: the same key never sends (or bills) the message twice.
  const { data: sent } = await api<{ data: SentSms }>(
    'POST',
    '/comms/sms',
    { to, from: senderId, message },
    { 'X-Idempotency-Key': randomUUID() },
  );
  console.log(`Message submitted: ${sent.messageId}`);
  console.log(`  status: ${sent.status}`);
  console.log(`  segments: ${sent.segments}`);
  console.log(`  cost: ${sent.cost}`);

  // The status is the send-time outcome (accepted, sent or failed). Handset delivery
  // receipts are not collected, which `dlrSupported: false` states explicitly.
  const { data: status } = await api<{ data: SmsStatus }>('GET', `/comms/sms/${encodeURIComponent(sent.messageId)}`);
  console.log(`Status lookup: ${status.status}`);
  console.log(`  dlrSupported: ${status.dlrSupported ?? false}`);
}

await main();
