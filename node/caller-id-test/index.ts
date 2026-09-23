// Test which caller ID a route really delivers: a test handset in the destination
// country receives a call and reports the number it displayed.
//
//   node caller-id-test/index.ts <routeId> +14155550199 "United States"

import { setTimeout as sleep } from 'node:timers/promises';

const BASE_URL = (process.env.PACKETEXCHANGE_BASE_URL ?? 'https://packetexchange.io/api/v1').replace(/\/$/, '');
const API_KEY = process.env.PACKETEXCHANGE_API_KEY;

interface ApiErrorBody {
  error?: { code?: string; message?: string; details?: { path: string; message: string }[] };
}

interface Quota {
  costPerTest: number;
  limitPerHour: number;
  remaining: number;
}

interface CliTest {
  id: string;
  status: string;
  reportedCli: string | null;
  displayedCorrectly: boolean | null;
  resultNotes: string | null;
}

const FINAL = new Set(['completed', 'failed', 'not_tested', 'cancelled']);
const POLL_EVERY_MS = 10_000;
const GIVE_UP_AFTER_MS = 10 * 60_000;

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
  const [routeId, callerId, country] = process.argv.slice(2);
  if (!routeId || !callerId || !country) {
    console.error('Usage: node caller-id-test/index.ts <route-id> <caller-id> <country>');
    process.exit(2);
  }
  if (!API_KEY) {
    console.error('Set PACKETEXCHANGE_API_KEY first (see .env.example).');
    process.exit(2);
  }

  // Each test is a real call. It is charged only if the route rang; the live price is in the quota.
  const { data: quota } = await api<{ data: Quota }>('GET', '/cli-tests/quota');
  console.log(
    `Caller-ID test price: $${quota.costPerTest.toFixed(2)} per test, charged only if the route rang (${quota.remaining} of ${quota.limitPerHour} left this hour)`,
  );

  // The country must be the route's own destination country, for example "United Kingdom".
  const { data: created } = await api<{ data: CliTest }>('POST', '/cli-tests', {
    routeId,
    displayCli: callerId,
    testCountry: country,
  });
  console.log(`Test queued: ${created.id} (status ${created.status})`);

  const deadline = Date.now() + GIVE_UP_AFTER_MS;
  let lastStatus = created.status;
  for (;;) {
    const { data: test } = await api<{ data: CliTest }>('GET', `/cli-tests/${created.id}`);
    if (test.status !== lastStatus) {
      console.log(`  status: ${test.status}`);
      lastStatus = test.status;
    }
    if (FINAL.has(test.status)) {
      console.log(`Result: ${test.status}`);
      console.log(`  reportedCli: ${test.reportedCli ?? 'none'}`);
      console.log(`  displayedCorrectly: ${test.displayedCorrectly ?? 'unknown'}`);
      console.log(`  resultNotes: ${test.resultNotes ?? 'none'}`);
      return;
    }
    if (Date.now() + POLL_EVERY_MS > deadline) {
      console.log(`Still running after 10 minutes; check GET /cli-tests/${created.id} later.`);
      return;
    }
    await sleep(POLL_EVERY_MS);
  }
}

await main();
