# Check SMS delivery status (Python)

Reads what happened to a message you sent with `GET /comms/sms/{messageId}`: its current status and a timeline of every step, `queued`, `sent`, then `delivered` or `failed`, each with a timestamp and where it came from.

## Cost

Free.

## Good to know

- `delivered` only ever comes from a carrier delivery receipt. On a route that returns no receipts the message stays `sent` with `awaitingReceipt: true`; `routeReturnsReceipts` says whether the route has returned any receipts in the last 30 days.
- On failure, `errorCode` is `SELLER_REJECTED`, `NO_ENDPOINT`, `UNDELIVERABLE`, `EXPIRED` or `REJECTED`, and the timeline step carries the carrier's own status and error values.
- To be told instead of polling, subscribe to the `sms.delivered` and `sms.failed` webhooks.
- An id that is not on your account answers `200` with status `not_found`; the example reports it and exits with code 1.
- Messages sent with a test key are simulated: their timeline ends at `accepted` and no receipt follows.
- Scoped API keys need the `sms:send` scope.

## Run

From the `python` folder, with `PACKETEXCHANGE_API_KEY` set (see the [Python README](../README.md) for setup):

```bash
python sms-status/main.py <message-id>
```

`<message-id>`: the `messageId` returned when the message was sent (see the [send-sms](../send-sms) example).

To try it without spending anything, run it against the [mock API](../../mock): start `node mock/server.mjs` from the repository root, then set `PACKETEXCHANGE_BASE_URL=http://127.0.0.1:4010/api/v1` and `PACKETEXCHANGE_API_KEY=wmmn_test_sk_mock`. The mock answers message id `5d0c8a1e-2f3b-4c6d-9e7f-8a9b0c1d2e3f` with a delivered message and its full timeline.

## API reference

- `GET /comms/sms/{messageId}`

Full reference: [packetexchange.io/api-docs](https://packetexchange.io/api-docs)
