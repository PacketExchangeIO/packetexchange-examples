# Send a transactional SMS (Go)

Sends one transactional message, an appointment reminder, with `POST /comms/sms`, then reads its status with `GET /comms/sms/{messageId}`. Send messages only to people who expect them, such as customers who booked the appointment.

## Cost

Billed per segment at the route price plus the platform fee. A segment is up to 160 GSM-7 or 70 UCS-2 characters (fewer per segment when a message is split). The response states `segments` and `cost`.

## Good to know

- The status in the send response is the **send-time** outcome (`accepted`, `sent` or `failed`). Delivery is confirmed later by a carrier receipt, when the route returns one: follow it with the [sms-status](../sms-status) example or the `sms.delivered` and `sms.failed` webhooks.
- Omit `routeId` and Smart Routing picks a route for the destination; `strategy` can be `cheapest`, `best_quality` or `balanced`.
- The `sms.sent` webhook event reports each accepted message.
- Sending and the status lookup need the `sms:send` scope.

## Run

From the `go` folder, with `PACKETEXCHANGE_API_KEY` set (see the [Go README](../README.md) for setup):

```bash
go run ./send-sms +14155550100 Riverside
```

`<to>`: the recipient in E.164 format. `<sender-id>`: a number or an alphanumeric sender (letters, digits, spaces and `. + _ -`, up to 30 characters). `[message]`: optional; defaults to an appointment reminder.

To try it without spending anything, run it against the [mock API](../../mock): start `node mock/server.mjs` from the repository root, then set `PACKETEXCHANGE_BASE_URL=http://127.0.0.1:4010/api/v1` and `PACKETEXCHANGE_API_KEY=wmmn_test_sk_mock`.

## API reference

- `POST /comms/sms`
- `GET /comms/sms/{messageId}`

Full reference: [packetexchange.io/api-docs](https://packetexchange.io/api-docs)
