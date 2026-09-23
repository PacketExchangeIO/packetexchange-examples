# Send a transactional SMS (Java)

Sends one transactional message, an appointment reminder, with `POST /comms/sms`, then reads its status with `GET /comms/sms/{messageId}`. Send messages only to people who expect them, such as customers who booked the appointment.

## Cost

Billed per segment at the route price plus the platform fee. A segment is up to 160 GSM-7 or 70 UCS-2 characters (fewer per segment when a message is split). The response states `segments` and `cost`.

## Good to know

- The status is the **send-time** outcome (`accepted`, `sent` or `failed`), not a handset delivery receipt. Handset receipts are not collected, and the status lookup says so with `dlrSupported: false`.
- Omit `routeId` and Smart Routing picks a route for the destination; `strategy` can be `cheapest`, `best_quality` or `balanced`.
- The `sms.sent` webhook event reports each accepted message.
- Sending needs the `sms:send` scope. The status lookup is not available to scoped keys; use a full-access key.

## Run

From the `java` folder, with `PACKETEXCHANGE_API_KEY` set (see the [Java README](../README.md) for setup):

```bash
java -cp 'target/dependency/*' send-sms/Main.java +14155550100 Riverside
```

`<to>`: the recipient in E.164 format. `<sender-id>`: a number or an alphanumeric sender (letters, digits, spaces and `. + _ -`, up to 30 characters). `[message]`: optional; defaults to an appointment reminder.

To try it without spending anything, run it against the [mock API](../../mock): start `node mock/server.mjs` from the repository root, then set `PACKETEXCHANGE_BASE_URL=http://127.0.0.1:4010/api/v1` and `PACKETEXCHANGE_API_KEY=wmmn_test_sk_mock`.

## API reference

- `POST /comms/sms`
- `GET /comms/sms/{messageId}`

Full reference: [packetexchange.io/api-docs](https://packetexchange.io/api-docs)
