// Top up your PacketExchange balance with USDC on Base using the x402 payment protocol.
// THIS MOVES REAL FUNDS from the wallet in X402_PRIVATE_KEY, so the payment step needs --confirm.
//
//   node x402-topup/index.ts 25            shows what would be paid, pays nothing
//   node x402-topup/index.ts 25 --confirm  signs and pays
//
// The exchange: POST without X-PAYMENT -> HTTP 402 with the payment requirements; sign an
// EIP-3009 USDC transferWithAuthorization for exactly those requirements; POST again with it
// base64-encoded in X-PAYMENT. The platform settles it on-chain and credits the balance.

import { randomBytes } from 'node:crypto';
import { getAddress, type Hex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

const BASE_URL = (process.env.PACKETEXCHANGE_BASE_URL ?? 'https://packetexchange.io/api/v1').replace(/\/$/, '');
const API_KEY = process.env.PACKETEXCHANGE_API_KEY;
const PRIVATE_KEY = process.env.X402_PRIVATE_KEY;

interface ApiErrorBody {
  error?: { code?: string; message?: string; details?: { path: string; message: string }[] };
}

interface PaymentRequirements {
  scheme: string;
  network: string;
  maxAmountRequired: string;
  payTo: string;
  asset: string;
  maxTimeoutSeconds: number;
  extra: { name: string; version: string };
}

interface Challenge {
  x402Version: number;
  accepts: PaymentRequirements[];
  error?: string;
}

interface TopupResult {
  topupId: string;
  status: string;
  txHash?: string;
  newBalance?: number;
  message?: string;
}

// The only token and networks this example will pay on. Checking them stops a wrong or
// tampered challenge from making you sign for a different asset or chain.
const NETWORKS: Record<string, { chainId: number; usdc: string }> = {
  base: { chainId: 8453, usdc: '0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913' },
  'base-sepolia': { chainId: 84532, usdc: '0x036CbD53842c5426634e7929541eC2318f3dCF7e' },
};

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

/** POSTs the top-up. A 402 is part of the protocol here, so it is returned instead of treated as an error. */
async function postTopup(amountUsd: number, payment?: string): Promise<{ status: number; body: unknown }> {
  let res: Response;
  try {
    res = await fetch(`${BASE_URL}/topups/x402`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${API_KEY}`,
        'Content-Type': 'application/json',
        Accept: 'application/json',
        ...(payment ? { 'X-PAYMENT': payment } : {}),
      },
      body: JSON.stringify({ amountUsd }),
      // Settlement waits for the on-chain transfer, so allow longer than a normal call.
      signal: AbortSignal.timeout(120_000),
    });
  } catch (err) {
    console.error(`Network error: ${(err as Error).message}`);
    process.exit(1);
  }
  const text = await res.text();
  if (!res.ok && res.status !== 402) exitWithApiError(res, text);
  return { status: res.status, body: JSON.parse(text) };
}

/** Refuses to sign unless the challenge asks for exactly the amount, token and chain expected. */
function checkRequirements(reqs: PaymentRequirements | undefined, amountUsd: number): PaymentRequirements {
  const network = reqs ? NETWORKS[reqs.network] : undefined;
  const expectedAtomic = String(Math.round(amountUsd * 1_000_000)); // USDC has 6 decimals
  const problem =
    !reqs ? 'the 402 response has no payment requirements'
    : reqs.scheme !== 'exact' ? `unsupported scheme "${reqs.scheme}"`
    : !network ? `unsupported network "${reqs.network}"`
    : reqs.asset.toLowerCase() !== network.usdc.toLowerCase() ? `asset ${reqs.asset} is not USDC on ${reqs.network}`
    : reqs.maxAmountRequired !== expectedAtomic ? `amount ${reqs.maxAmountRequired} does not match ${expectedAtomic}`
    : null;
  if (problem) {
    console.error(`Refusing to pay: ${problem}.`);
    process.exit(1);
  }
  return reqs as PaymentRequirements;
}

/** Signs an EIP-3009 transferWithAuthorization and encodes it as the X-PAYMENT header value. */
async function buildPayment(reqs: PaymentRequirements, privateKey: Hex): Promise<string> {
  const account = privateKeyToAccount(privateKey);
  const now = Math.floor(Date.now() / 1000);
  const authorization = {
    from: account.address,
    to: getAddress(reqs.payTo),
    value: reqs.maxAmountRequired,
    // A little clock-skew allowance before, and the challenge's own timeout after.
    validAfter: String(now - 600),
    validBefore: String(now + reqs.maxTimeoutSeconds),
    // A fresh random nonce makes the authorization single-use on-chain.
    nonce: `0x${randomBytes(32).toString('hex')}` as Hex,
  };
  const signature = await account.signTypedData({
    domain: {
      name: reqs.extra.name,
      version: reqs.extra.version,
      chainId: NETWORKS[reqs.network].chainId,
      verifyingContract: getAddress(reqs.asset),
    },
    types: {
      TransferWithAuthorization: [
        { name: 'from', type: 'address' },
        { name: 'to', type: 'address' },
        { name: 'value', type: 'uint256' },
        { name: 'validAfter', type: 'uint256' },
        { name: 'validBefore', type: 'uint256' },
        { name: 'nonce', type: 'bytes32' },
      ],
    },
    primaryType: 'TransferWithAuthorization',
    message: {
      ...authorization,
      value: BigInt(authorization.value),
      validAfter: BigInt(authorization.validAfter),
      validBefore: BigInt(authorization.validBefore),
    },
  });
  const payload = { x402Version: 1, scheme: reqs.scheme, network: reqs.network, payload: { signature, authorization } };
  return Buffer.from(JSON.stringify(payload)).toString('base64');
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  const confirmed = args.includes('--confirm');
  const [amountArg] = args.filter((a) => a !== '--confirm');
  const amountUsd = Number(amountArg);
  if (!amountArg || !Number.isFinite(amountUsd) || amountUsd <= 0) {
    console.error('Usage: node x402-topup/index.ts <amount-usd> [--confirm]');
    process.exit(2);
  }
  if (!API_KEY) {
    console.error('Set PACKETEXCHANGE_API_KEY first (see .env.example).');
    process.exit(2);
  }
  if (!PRIVATE_KEY || !/^0x[0-9a-fA-F]{64}$/.test(PRIVATE_KEY)) {
    console.error('Set X402_PRIVATE_KEY first (see .env.example): the 0x-prefixed private key of the paying wallet.');
    process.exit(2);
  }

  // Step 1: ask what to pay. This request moves no money.
  const first = await postTopup(amountUsd);
  if (first.status === 201) {
    console.log(`x402 top-ups are not enabled: ${(first.body as { data: TopupResult }).data.message}`);
    return;
  }
  const reqs = checkRequirements((first.body as Challenge).accepts?.[0], amountUsd);
  console.log(`Payment required: ${amountUsd} USDC on ${reqs.network} to ${reqs.payTo}`);

  if (!confirmed) {
    console.error('Re-run with --confirm to sign and send this payment.');
    process.exit(2);
  }

  // Step 2: sign for exactly these requirements and send the same request again.
  const second = await postTopup(amountUsd, await buildPayment(reqs, PRIVATE_KEY as Hex));
  if (second.status === 402) {
    console.error(`Payment not accepted: ${(second.body as Challenge).error}`);
    process.exit(1);
  }
  const { data: topup } = second.body as { data: TopupResult };
  console.log(`Top-up confirmed: ${topup.topupId}`);
  console.log(`  txHash: ${topup.txHash}`);
  console.log(`  newBalance: ${topup.newBalance}`);
}

await main();
