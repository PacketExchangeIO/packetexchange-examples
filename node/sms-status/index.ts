// Read what happened to a message you sent: every step from queued to delivered or
// failed, with timestamps. "delivered" only ever comes from a carrier receipt.
//
//   node sms-status/index.ts <messageId>

const BASE_URL = (process.env.PACKETEXCHANGE_BASE_URL ?? 'https://packetexchange.io/api/v1').replace(/\/$/, '');
const API_KEY = process.env.PACKETEXCHANGE_API_KEY;

interface ApiErrorBody {
  error?: { code?: string; message?: string; details?: { path: string; message: string }[] };
}

interface TimelineStep {
  status: string;
  at: string;
  source: string;
  errorCode?: string | null;
  carrierStatus?: string | null;
}

interface SmsStatus {
  messageId: string;
  status: string;
  errorCode?: string | null;
  timeline?: TimelineStep[];
  awaitingReceipt?: boolean;
  routeReturnsReceipts?: boolean | null;
}

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
  const [messageId] = process.argv.slice(2);
  if (!messageId) {
    console.error('Usage: node sms-status/index.ts <message-id>');
    process.exit(2);
  }
  if (!API_KEY) {
    console.error('Set PACKETEXCHANGE_API_KEY first (see .env.example).');
    process.exit(2);
  }

  const { data: sms } = await api<{ data: SmsStatus }>('GET', `/comms/sms/${encodeURIComponent(messageId)}`);

  // An id that is not on your account answers 200 with status not_found.
  if (sms.status === 'not_found') {
    console.error(`No message ${messageId} on this account.`);
    process.exit(1);
  }
  console.log(`Message ${sms.messageId}: ${sms.status}`);
  for (const step of sms.timeline ?? []) {
    const extra = [step.source, step.carrierStatus, step.errorCode].filter(Boolean).join(', ');
    console.log(`  - ${step.status} at ${step.at} (${extra})`);
  }
  if (sms.errorCode) console.log(`  errorCode: ${sms.errorCode}`);
  // A route that returns no receipts leaves the message at "sent" for good.
  console.log(`  awaitingReceipt: ${sms.awaitingReceipt ?? false}`);
  console.log(`  routeReturnsReceipts: ${sms.routeReturnsReceipts ?? 'unknown'}`);
}

await main();
