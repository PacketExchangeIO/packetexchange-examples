# Look up a phone number (Go)

Looks up one number with `GET /lookup/{number}` before you message or call it: whether it is a valid E.164 number, its country, line type (mobile, fixed, toll free or premium), the network its number range belongs to, blocked and high-risk flags, and the cheapest live voice and SMS price to reach it.

## Cost

Free. Lookups are limited to 60 a minute per caller, and an answer is cached for up to 10 minutes.

## Good to know

- The lookup is prefix-based: it is built from the marketplace's rate decks and public number-range data, and no carrier network query is made. It cannot tell you whether a number is in service, and a ported number shows the network its range was allocated to.
- Send the number in international format (`+447700900123` or `00447700900123`; spaces and dashes are ignored). A national number such as `07700900123` is answered with `valid: false` and a `reason`, not an HTTP error.
- `pricing.voice` and `pricing.sms` are the cheapest live public route for the number, or `null` when none serves it. Where a route prices SMS per network, `pricing.sms.network` says which network the rate is for and `pricing.sms.countryRate` is its price for other networks.
- Scoped API keys need the `routes:read` scope.

## Run

From the `go` folder, with `PACKETEXCHANGE_API_KEY` set (see the [Go README](../README.md) for setup):

```bash
go run ./number-lookup +447700900123
```

`<number>`: the number to look up, in international format.

To try it without spending anything, run it against the [mock API](../../mock): start `node mock/server.mjs` from the repository root, then set `PACKETEXCHANGE_BASE_URL=http://127.0.0.1:4010/api/v1` and `PACKETEXCHANGE_API_KEY=wmmn_test_sk_mock`.

## API reference

- `GET /lookup/{number}`

Full reference: [packetexchange.io/api-docs](https://packetexchange.io/api-docs)
