# Make a call (Python)

Places one outbound call with `POST /comms/calls` and prints the outcome, duration and cost, then finds the call in your history with `GET /comms/calls`. The request returns when the call has ended (answered and hung up, not answered, or `maxDuration` reached), so the client timeout is set longer than `maxDuration`.

## Cost

Billed after the call ends: billable seconds, rounded up to the route billing increment (for example `6/6` or `60/60`), at the route price plus the platform fee. The response states `billableSeconds`, `billingIncrement` and `cost`.

## Good to know

- `status` is `answered`, `no_answer`, `busy` or `failed`. With a test key nothing is dialled and the status is `accepted`.
- `from` is the caller ID to present, in E.164 format. Present only caller IDs you are entitled to use.
- The `call.completed` webhook event reports each finished call.
- Placing calls needs the `voice:send` scope. The call history is not available to scoped keys; use a full-access key.

## Run

From the `python` folder, with `PACKETEXCHANGE_API_KEY` set (see the [Python README](../README.md) for setup):

```bash
python make-call/main.py +14155550100 +14155550199 60
```

`<to>`: the number to call. `<caller-id>`: the caller ID to present. `[max-duration-seconds]`: optional, default `60` (10 to 3600).

To try it without spending anything, run it against the [mock API](../../mock): start `node mock/server.mjs` from the repository root, then set `PACKETEXCHANGE_BASE_URL=http://127.0.0.1:4010/api/v1` and `PACKETEXCHANGE_API_KEY=wmmn_test_sk_mock`.

## API reference

- `POST /comms/calls`
- `GET /comms/calls`

Full reference: [packetexchange.io/api-docs](https://packetexchange.io/api-docs)
