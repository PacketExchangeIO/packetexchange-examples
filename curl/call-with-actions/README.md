# Call with actions and collect a key press (curl)

Calls a customer to confirm an appointment. `POST /comms/calls` with `async: true` returns as soon as the number is being dialled (HTTP 202 with a `callId`), and `actions` make the answered call speak a message, ask for one key press with `gather`, and say goodbye. The example then polls `GET /comms/calls/{id}` until the call ends and prints the outcome, the cost and the key pressed.

## Cost

Billed after the call ends: billable seconds, rounded up to the route billing increment, at the route price plus the platform fee. There is no charge for spoken text.

## Good to know

- Actions run in order once the call is answered: `say` (text spoken in `en`, `es`, `fr`, `de`, `pt` or `hi`), `play` (an https MP3 URL, up to 2 MB), `gather` (collect up to 20 keys), `pause` and `hangup`. Up to 10 per call. The call ends when the actions finish.
- Keys collected by `gather` are reported when the call ends, in `gathered` on `GET /comms/calls/{id}` and by the `call.gathered` webhook. Nothing pressed shows as `no_input`.
- Final statuses: `completed`, `no_answer`, `busy` and `failed`, with `hangupReason` in plain words. The example polls every 2 seconds for up to 5 minutes; in production, subscribe to the `call.ringing`, `call.answered`, `call.gathered` and `call.completed` webhooks instead.
- With a test key nothing is dialled and no actions run: the request returns the finished, simulated call (HTTP 200, status `accepted`) and no key press is reported.
- `from` is the caller ID to present, in E.164 format. Call only people who expect the call, such as customers with a booking.
- Scoped API keys need the `voice:send` scope.

## Run

From the `curl` folder, with `PACKETEXCHANGE_API_KEY` set (see the [curl README](../README.md) for setup):

```bash
./call-with-actions/example.sh +14155550100 +14155550199
```

`<to>`: the number to call. `<caller-id>`: the caller ID to present.

To try it without spending anything, run it against the [mock API](../../mock): start `node mock/server.mjs` from the repository root, then set `PACKETEXCHANGE_BASE_URL=http://127.0.0.1:4010/api/v1` and `PACKETEXCHANGE_API_KEY=wmmn_test_sk_mock`. The mock treats any `wmmn_live_sk_` key as live, so `PACKETEXCHANGE_API_KEY=wmmn_live_sk_mock` shows the 202 response and the call moving from `ringing` to `completed`.

## API reference

- `POST /comms/calls`
- `GET /comms/calls/{id}`

Full reference: [packetexchange.io/api-docs](https://packetexchange.io/api-docs)
