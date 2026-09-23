# Top up with USDC over x402 (Node.js)

Adds funds to your PacketExchange balance with USDC on Base, using the [x402](https://www.x402.org) payment protocol with `POST /topups/x402`. The first request, without an `X-PAYMENT` header, answers `402 Payment Required` with the payment requirements. The example checks them, signs an EIP-3009 USDC `transferWithAuthorization` for exactly that amount with your wallet key, and repeats the request with the signed payment in `X-PAYMENT`. PacketExchange settles it on-chain and credits your balance in the same response.

## Cost

**This moves real funds.** A confirmed run transfers the amount in USDC from the wallet in `X402_PRIVATE_KEY` to PacketExchange and credits the same amount in US dollars to your balance. The example only signs and pays when you pass `--confirm`; without it, it shows the payment requirements and stops. Your wallet does not pay gas: PacketExchange submits the signed authorization.

## Good to know

- Amounts from $5 to $50,000 per top-up. Top-ups are subject to velocity limits and, where it is enforced, identity verification (`403 KYC_REQUIRED`).
- Before signing, the example checks the challenge: scheme `exact`, network `base` or `base-sepolia`, the USDC contract for that network, and the exact amount you asked for. Keep checks like these in your own client.
- A replayed payment is not credited twice; the response returns the original top-up with `already: true`.
- If x402 top-ups are not enabled, the first request answers `201` with a message; the example prints it.
- Keep the private key out of source control and shell history. Use a dedicated wallet that holds only what you intend to spend.
- Scoped API keys need the `billing:write` scope.

## Run

From the `node` folder, with `PACKETEXCHANGE_API_KEY` set (see the [Node.js README](../README.md) for setup):

```bash
export X402_PRIVATE_KEY=0x...   # the paying wallet's private key; never commit it
node x402-topup/index.ts 25              # shows what would be paid, pays nothing
node x402-topup/index.ts 25 --confirm    # signs and pays
```

`<amount-usd>`: the amount to add, in US dollars. `--confirm`: sign and pay.

To try it without spending anything, run it against the [mock API](../../mock): start `node mock/server.mjs` from the repository root, then set `PACKETEXCHANGE_BASE_URL=http://127.0.0.1:4010/api/v1` and `PACKETEXCHANGE_API_KEY=wmmn_test_sk_mock`. The mock issues its challenge for network `base`, checks the signed payment and returns a fake transaction hash. No funds move.

## API reference

- `POST /topups/x402`

Full reference: [packetexchange.io/api-docs](https://packetexchange.io/api-docs)
