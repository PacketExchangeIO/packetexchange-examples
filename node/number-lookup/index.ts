// Look up a phone number before you message or call it: whether it is a valid E.164
// number, its country, line type and network, risk flags, and the cheapest live price.
//
//   node number-lookup/index.ts +447700900123

const BASE_URL = (process.env.PACKETEXCHANGE_BASE_URL ?? 'https://packetexchange.io/api/v1').replace(/\/$/, '');
const API_KEY = process.env.PACKETEXCHANGE_API_KEY;

interface ApiErrorBody {
  error?: { code?: string; message?: string; details?: { path: string; message: string }[] };
}

interface Price {
  rate: string;
  unit: string;
  routeId: string;
  routesServing: number;
}

interface Lookup {
  valid: boolean;
  reason: string | null;
  e164: string | null;
  internationalFormat: string | null;
  country: { iso: string | null; name: string } | null;
  numberType: string;
  network: { operator: string | null } | null;
  risk: { blocked: boolean; highRisk: boolean; reasons: string[] };
  pricing: { voice: Price | null; sms: Price | null };
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

/** One price line: the cheapest live route, or "no route" when none serves the number. */
function priceLine(label: string, price: Price | null): string {
  if (!price) return `  ${label}: no route`;
  return `  ${label}: ${price.rate}/${price.unit} via ${price.routeId} (${price.routesServing} routes serve it)`;
}

async function main(): Promise<void> {
  const [number] = process.argv.slice(2);
  if (!number) {
    console.error('Usage: node number-lookup/index.ts <number>');
    process.exit(2);
  }
  if (!API_KEY) {
    console.error('Set PACKETEXCHANGE_API_KEY first (see .env.example).');
    process.exit(2);
  }

  // Encode the number for use in the URL path, leading "+" included.
  const { data } = await api<{ data: Lookup }>('GET', `/lookup/${encodeURIComponent(number)}`);

  // A malformed number is a normal answer (valid: false), not an HTTP error.
  if (!data.valid) {
    console.log(`Not a valid number: ${data.reason}`);
    return;
  }
  console.log(`${data.e164} (${data.internationalFormat})`);
  console.log(`  country: ${data.country ? `${data.country.name} (${data.country.iso ?? 'shared dial code'})` : 'unknown'}`);
  console.log(`  numberType: ${data.numberType}`);
  // From number-range data: a ported number still shows the network its range belongs to.
  console.log(`  network: ${data.network?.operator ?? 'unknown'}`);
  console.log(`  risk: blocked ${data.risk.blocked}, highRisk ${data.risk.highRisk}`);
  for (const reason of data.risk.reasons) console.log(`    - ${reason}`);
  console.log(priceLine('voice', data.pricing.voice));
  console.log(priceLine('sms', data.pricing.sms));
}

await main();
