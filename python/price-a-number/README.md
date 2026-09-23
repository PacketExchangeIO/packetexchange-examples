# Price a number and preview routing (Python)

Ranks every marketplace route that serves one phone number by what it would actually charge for that number with `GET /routes/price-number`, then shows which route Smart Routing would pick for each strategy (`cheapest`, `best_quality`, `balanced`) with `GET /routes/resolve`.

## Cost

Free. Both endpoints only read prices; nothing is bought or dialled.

## Good to know

- A route with a rate sheet is priced by its longest matching prefix; a single-price route by its listed price. These are public list prices: negotiated prices and private grants are not applied.
- ASR and ACD figures on listings are **stated by the seller**, not measured by PacketExchange.
- `/routes/resolve` runs as your account, so it also considers private routes you have bought. It needs the `routes:read` scope.
- `/routes/price-number` also works without a key and is limited to 30 requests per minute.

## Run

From the `python` folder, with `PACKETEXCHANGE_API_KEY` set (see the [Python README](../README.md) for setup):

```bash
python price-a-number/main.py +447700900123
```

`<number>`: a full number or dial code, any formatting. `[voice|sms]`: optional, default `voice`.

To try it without spending anything, run it against the [mock API](../../mock): start `node mock/server.mjs` from the repository root, then set `PACKETEXCHANGE_BASE_URL=http://127.0.0.1:4010/api/v1` and `PACKETEXCHANGE_API_KEY=wmmn_test_sk_mock`.

## API reference

- `GET /routes/price-number`
- `GET /routes/resolve`

Full reference: [packetexchange.io/api-docs](https://packetexchange.io/api-docs)
