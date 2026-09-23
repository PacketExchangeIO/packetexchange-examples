# Verify a phone number by voice call (C#)

Sends a one-time code by voice call with `POST /verify/start` (channel `voice`), then checks the code the user types with `POST /verify/check`. When the call is answered, the code is read one digit at a time and repeated, then the call ends.

## Cost

Billed as the call that carries the code: the route rate per billing increment plus the platform fee. There is no separate verification fee and no text-to-speech surcharge. With a test key (`wmmn_test_sk_...`) nothing is dialled and the response includes `testCode`.

## Good to know

- **Supported languages for voice codes: `en` (English), `es` (Spanish), `fr` (French), `de` (German), `pt` (Portuguese) and `hi` (Hindi).** Any other language is refused with a `400` that lists these. SMS codes additionally support `ar`.
- `from` is the caller ID the call presents, in E.164 format.
- The same limits as SMS codes apply: 5 codes per number per hour, 30 seconds between codes to the same number, and a daily cap per account.
- A scoped API key needs the `verify:write` scope.

## Run

From the `csharp` folder, with `PACKETEXCHANGE_API_KEY` set (see the [C# README](../README.md) for setup):

```bash
dotnet run --project verify-voice -- +14155550100 +14155550199 es
```

`<to>`: the phone number to verify. `<caller-id>`: the caller ID to present. `[language]`: optional, default `en`.

To try it without spending anything, run it against the [mock API](../../mock): start `node mock/server.mjs` from the repository root, then set `PACKETEXCHANGE_BASE_URL=http://127.0.0.1:4010/api/v1` and `PACKETEXCHANGE_API_KEY=wmmn_test_sk_mock`. The mock always uses the code `123456`.

## API reference

- `POST /verify/start`
- `POST /verify/check`

Full reference: [packetexchange.io/api-docs](https://packetexchange.io/api-docs)
