// Search for a phone number, buy it, and point its calls at a SIP server or another number.
// Buying charges the setup price plus the first month, so it needs --confirm.
//
//   node phone-numbers/index.ts search 1415
//   node phone-numbers/index.ts buy <groupId> <skuId> --confirm
//   node phone-numbers/index.ts route <didId> sip sip.example.com:5060
//   node phone-numbers/index.ts route <didId> forward +14155550123

import { randomUUID } from 'node:crypto';

const BASE_URL = (process.env.PACKETEXCHANGE_BASE_URL ?? 'https://packetexchange.io/api/v1').replace(/\/$/, '');
const API_KEY = process.env.PACKETEXCHANGE_API_KEY;

interface ApiErrorBody {
  error?: { code?: string; message?: string; details?: { path: string; message: string }[] };
}

// While the number store is switched off, these endpoints answer 200 with this shape.
interface StoreDisabled {
  disabled: true;
  message: string;
}

interface SearchHit {
  groupId: string;
  country: string;
  city: string | null;
  typeName: string | null;
  dialingPrefix: string;
  skus: { skuId: string; channels: number; setupPrice: number; monthlyPrice: number }[];
}

interface Did {
  id: string;
  number: string | null;
  status: string;
  pointMode: string;
  pointsTo: string | null;
  setupPrice: string;
  monthlyPrice: string;
}

const USAGE = [
  'Usage: node phone-numbers/index.ts search [pattern]',
  '       node phone-numbers/index.ts buy <groupId> <skuId> --confirm',
  '       node phone-numbers/index.ts route <didId> sip|forward <target>',
].join('\n');

function exitIfStoreDisabled(data: unknown): void {
  const d = data as Partial<StoreDisabled> | undefined;
  if (d?.disabled) {
    console.log(`Number store unavailable: ${d.message}`);
    process.exit(0);
  }
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

async function search(pattern?: string): Promise<void> {
  const query = new URLSearchParams({ limit: '5' });
  if (pattern) query.set('pattern', pattern);
  // Search results are top-level fields of the body, not wrapped in `data`.
  const body = await api<{ hits?: SearchHit[]; data?: StoreDisabled }>('GET', `/dids/search?${query}`);
  exitIfStoreDisabled(body.data);
  const hits = body.hits ?? [];
  console.log(`${hits.length} number groups found:`);
  for (const h of hits) {
    const place = h.city ? `${h.country}, ${h.city}` : h.country;
    console.log(`  ${h.dialingPrefix}  ${place}  ${h.typeName ?? ''}  groupId ${h.groupId}`);
    for (const s of h.skus) {
      console.log(`    skuId ${s.skuId}: setup $${s.setupPrice.toFixed(2)}, monthly $${s.monthlyPrice.toFixed(2)}, ${s.channels} channels`);
    }
  }
}

async function buy(groupId: string, skuId: string, confirmed: boolean): Promise<void> {
  if (!confirmed) {
    console.error('Buying a number charges the setup price plus the first month to your balance.');
    console.error('Re-run with --confirm to place the order.');
    process.exit(2);
  }
  // This spends money. The idempotency key guarantees a retried request orders one number, not two.
  const { data } = await api<{ data: Did | StoreDisabled }>(
    'POST',
    '/dids/buy',
    { groupId, skuId },
    { 'X-Idempotency-Key': randomUUID() },
  );
  exitIfStoreDisabled(data);
  const did = data as Did;
  console.log(`Number ordered: ${did.id}`);
  console.log(`  status: ${did.status}`);
  // The number is assigned when provisioning completes; until then it is null.
  console.log(`  number: ${did.number ?? 'pending'}`);
  console.log(`  setupPrice: ${did.setupPrice}`);
  console.log(`  monthlyPrice: ${did.monthlyPrice}`);
}

async function route(didId: string, mode: 'sip' | 'forward', target: string): Promise<void> {
  // sip: host[:port] of your SIP server. forward: an E.164 number to ring instead.
  const { data } = await api<{ data: Did | StoreDisabled }>(
    'PATCH',
    `/dids/${encodeURIComponent(didId)}/routing`,
    { mode, target },
  );
  exitIfStoreDisabled(data);
  const did = data as Did;
  console.log(`Number ${did.id} now routes to ${did.pointMode} ${did.pointsTo}`);
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const confirmed = args.includes('--confirm');
  const [command, ...rest] = args.filter((a) => a !== '--confirm');
  if (!API_KEY) {
    console.error('Set PACKETEXCHANGE_API_KEY first (see .env.example).');
    process.exit(2);
  }

  if (command === 'search' && rest.length <= 1) return search(rest[0]);
  if (command === 'buy' && rest.length === 2) return buy(rest[0], rest[1], confirmed);
  if (command === 'route' && rest.length === 3 && (rest[1] === 'sip' || rest[1] === 'forward')) {
    return route(rest[0], rest[1], rest[2]);
  }
  console.error(USAGE);
  process.exit(2);
}

await main();
