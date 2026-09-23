// Rank every marketplace route for one phone number by what it would really cost, then
// show which route Smart Routing would pick for each strategy.
//
//   node price-a-number/index.ts +447700900123
//   node price-a-number/index.ts 447700900123 sms

const BASE_URL = (process.env.PACKETEXCHANGE_BASE_URL ?? 'https://packetexchange.io/api/v1').replace(/\/$/, '');
const API_KEY = process.env.PACKETEXCHANGE_API_KEY;

interface ApiErrorBody {
  error?: { code?: string; message?: string; details?: { path: string; message: string }[] };
}

interface PricedRoute {
  id: string;
  destination: string;
  matchedPrefix: string;
  rate: string;
  expectedAsr: string | null;
}

interface PriceNumberResult {
  unit: 'min' | 'msg';
  total: number;
  routes: PricedRoute[];
  notice: 'sanctioned' | null;
}

interface ResolvedRoute {
  id: string;
  destinationName: string;
  price: string;
}

interface ResolveResult {
  selected: ResolvedRoute | null;
}

const STRATEGIES = ['cheapest', 'best_quality', 'balanced'] as const;

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
  const [number, type = 'voice'] = process.argv.slice(2);
  if (!number || (type !== 'voice' && type !== 'sms')) {
    console.error('Usage: node price-a-number/index.ts <number> [voice|sms]');
    process.exit(2);
  }
  if (!API_KEY) {
    console.error('Set PACKETEXCHANGE_API_KEY first (see .env.example).');
    process.exit(2);
  }
  const unit = type === 'sms' ? 'msg' : 'min';

  // Each route is priced for this exact number: the longest matching rate-sheet prefix,
  // or the listing's flat price. ASR figures are stated by the seller, not measured.
  const query = new URLSearchParams({ number, type });
  const { data: priced } = await api<{ data: PriceNumberResult }>('GET', `/routes/price-number?${query}`);
  if (priced.notice === 'sanctioned') {
    console.log('No routes: the destination is embargoed.');
  } else {
    console.log(`${priced.total} routes serve ${number} (${type}), cheapest first:`);
    for (const r of priced.routes.slice(0, 5)) {
      const asr = r.expectedAsr === null ? 'ASR n/a' : `ASR ${r.expectedAsr}% (seller-stated)`;
      console.log(`  ${r.rate}/${priced.unit}  ${r.destination}  prefix ${r.matchedPrefix}  ${asr}  ${r.id}`);
    }
  }

  // Resolve runs as your account, so it also sees private routes you have bought.
  for (const strategy of STRATEGIES) {
    const q = new URLSearchParams({ to: number, type, strategy });
    const { data } = await api<{ data: ResolveResult }>('GET', `/routes/resolve?${q}`);
    const s = data.selected;
    console.log(
      s
        ? `Strategy ${strategy}: ${s.price}/${unit} via ${s.id} (${s.destinationName})`
        : `Strategy ${strategy}: no route`,
    );
  }
}

await main();
