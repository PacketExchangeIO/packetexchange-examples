// Create an AI voice agent, try one conversation turn in text, and optionally attach it
// to a voice campaign so it handles the answered calls.
//
//   node ai-voice-agent/index.ts
//   node ai-voice-agent/index.ts <campaignId>

const BASE_URL = (process.env.PACKETEXCHANGE_BASE_URL ?? 'https://packetexchange.io/api/v1').replace(/\/$/, '');
const API_KEY = process.env.PACKETEXCHANGE_API_KEY;

interface ApiErrorBody {
  error?: { code?: string; message?: string; details?: { path: string; message: string }[] };
}

interface Voice {
  id: string;
  name: string;
  language: string;
  is_pro: boolean;
}

interface Agent {
  id: string;
}

interface Turn {
  reply: string;
  action: 'continue' | 'end' | 'transfer';
}

// The agent's script. A confirmation call to someone who booked an appointment is a
// transactional, expected call; keep agents to calls the recipient has agreed to receive.
const AGENT = {
  name: 'Appointment confirmation',
  language: 'en',
  firstMessage:
    'Hello, this is Riverside Clinic calling to confirm your appointment tomorrow at 10:30. Can you still make it?',
  systemPrompt: [
    'You confirm appointments for Riverside Clinic.',
    'Ask whether the person can attend their appointment tomorrow at 10:30.',
    'If they can, thank them and end the call. If they cannot, offer to have the clinic call them back to reschedule.',
    'Keep every reply short and polite.',
  ].join(' '),
  guardrails:
    'Never ask for payment details, passwords or medical information. If the person asks to stop receiving calls, confirm and end the call.',
  maxCallSeconds: 180,
};

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
  const [campaignId] = process.argv.slice(2);
  if (!API_KEY) {
    console.error('Set PACKETEXCHANGE_API_KEY first (see .env.example).');
    process.exit(2);
  }

  // Prefer a standard English voice; premium voices are listed too.
  const { data: voices } = await api<{ data: Voice[] }>('GET', '/ai-agents/voices');
  const voice = voices.find((v) => v.language === 'en' && !v.is_pro) ?? voices[0];
  if (!voice) {
    console.error('No voices are available right now.');
    process.exit(1);
  }
  console.log(`Using voice: ${voice.name} (${voice.id})`);

  const { data: agent } = await api<{ data: Agent }>('POST', '/ai-agents', { ...AGENT, voiceId: voice.id });
  console.log(`Agent created: ${agent.id}`);

  // Simulating a turn places no call and is not billed.
  const { data: turn } = await api<{ data: Turn }>('POST', `/ai-agents/${agent.id}/simulate`, {
    message: 'Yes, I can still make it.',
  });
  console.log(`Simulated reply: ${turn.reply}`);
  console.log(`  action: ${turn.action}`);

  // Agents run on outbound voice campaigns. The campaign must be a draft, ready or paused.
  if (campaignId) {
    await api('PUT', `/dialer/campaigns/${encodeURIComponent(campaignId)}`, { aiAgentId: agent.id });
    console.log(`Attached agent to campaign ${campaignId}`);
  }
}

await main();
