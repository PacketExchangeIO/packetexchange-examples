# Verify a phone number by SMS (Java)

Sends a one-time code by SMS with `POST /verify/start`, then checks the code the user types with `POST /verify/check`. PacketExchange generates the code, stores only a keyed hash of it, and enforces expiry (10 minutes by default), five attempts and single use. A wrong code comes back as status `denied`, not as an HTTP error.

## Cost

Billed as the SMS that carries the code: the route rate per segment plus the platform fee. There is no separate verification fee. With a test key (`wmmn_test_sk_...`) nothing is sent, the charge is simulated against test credit, and the response includes `testCode` so you can finish the flow.

## Good to know

- Limits: 5 codes per number per hour, 30 seconds between codes to the same number, and a daily cap per account. A limit answers `429` with `details.retryAfterSeconds`.
- Embargoed destinations, premium-rate and other high-risk ranges, and numbers on your Do-Not-Contact list are refused with `400`.
- SMS codes can be sent in `en`, `es`, `fr`, `de`, `pt`, `hi` and `ar` (pass `language`).
- A scoped API key needs the `verify:write` scope.

## Run

From the `java` folder, with `PACKETEXCHANGE_API_KEY` set (see the [Java README](../README.md) for setup):

```bash
java -cp 'target/dependency/*' verify-sms/Main.java +14155550100
```

`<to>`: the phone number to verify, in E.164 format.

To try it without spending anything, run it against the [mock API](../../mock): start `node mock/server.mjs` from the repository root, then set `PACKETEXCHANGE_BASE_URL=http://127.0.0.1:4010/api/v1` and `PACKETEXCHANGE_API_KEY=wmmn_test_sk_mock`. The mock always uses the code `123456`.

## API reference

- `POST /verify/start`
- `POST /verify/check`

Full reference: [packetexchange.io/api-docs](https://packetexchange.io/api-docs)
