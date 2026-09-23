// Send a one-time code by voice call with the Verify API, then check the code the user typed.
// The call reads the code digit by digit, twice. Voice languages: en, es, fr, de, pt, hi.
//
//   node verify-voice/index.ts +14155550100 +14155550199 es

import { randomUUID } from 'node:crypto';
import { createInterface } from 'node:readline/promises';

const BASE_URL = (process.env.PACKETEXCHANGE_BASE_URL ?? 'https://packetexchange.io/api/v1').replace(/\/$/, '');
const API_KEY = process.env.PACKETEXCHANGE_API_KEY;

interface ApiErrorBody {
  error?: { code?: string; message?: string; details?: { path: string; message: string }[] };
}

interface VerifyStart {
  verificationId: string;
  expiresAt: string;
  testCode?: string;
}

interface VerifyCheck {
  status: 'approved' | 'denied' | 'expired' | 'max_attempts';
  attemptsRemaining: number;
  reason?: string;
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
  const [to, callerId, language = 'en'] = process.argv.slice(2);
  if (!to || !callerId) {
    console.error('Usage: node verify-voice/index.ts <to> <caller-id> [language]');
    process.exit(2);
  }
  if (!API_KEY) {
    console.error('Set PACKETEXCHANGE_API_KEY first (see .env.example).');
    process.exit(2);
  }

  // `from` is the caller ID the code call presents. An unsupported language is refused
  // with a 400 that lists the supported ones.
  const { data: started } = await api<{ data: VerifyStart }>(
    'POST',
    '/verify/start',
    { to, channel: 'voice', from: callerId, language },
    { 'X-Idempotency-Key': randomUUID() },
  );
  console.log(`Verification call placed to ${to} (language: ${language})`);
  console.log(`  verificationId: ${started.verificationId}`);
  console.log(`  expiresAt: ${started.expiresAt}`);
  // Only test keys return the code, because nothing is actually dialled.
  if (started.testCode) console.log(`  testCode: ${started.testCode}`);

  const rl = createInterface({ input: process.stdin, output: process.stdout });
  const code = (await rl.question('Enter the code: ')).trim();
  rl.close();

  const { data: result } = await api<{ data: VerifyCheck }>('POST', '/verify/check', {
    verificationId: started.verificationId,
    code,
  });
  console.log(`Check result: ${result.status}${result.reason ? ` (${result.reason})` : ''}`);
  console.log(`  attemptsRemaining: ${result.attemptsRemaining}`);
}

await main();
