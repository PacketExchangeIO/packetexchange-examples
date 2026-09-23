# Test a caller ID on a route (Python)

Requests a caller-ID test on a route with `POST /cli-tests`, then polls `GET /cli-tests/{id}` until the result is in. A test handset in the destination country receives a real call over the route and reports the caller ID it displayed, so you can see whether the route delivers the number you present.

## Cost

**Each test costs $0.50, charged only if the route rang.** A test that could not be placed, or a route that did not ring, is not charged. `GET /cli-tests/quota` returns the current price and your remaining tests this hour; the example prints both before starting.

## Good to know

- `testCountry` must be the route's own destination country, for example `United Kingdom`.
- Voice routes only. A private route must be one you own or have bought.
- Final statuses: `completed` (see `reportedCli` and `displayedCorrectly`), `failed`, `not_tested` or `cancelled`. The example polls every 10 seconds for up to 10 minutes.
- To test a switch that is not hosted on PacketExchange, use `POST /cli-tests/quick` with its SIP address instead of a route id.
- Scoped API keys need the `dialer:write` scope.

## Run

From the `python` folder, with `PACKETEXCHANGE_API_KEY` set (see the [Python README](../README.md) for setup):

```bash
python caller-id-test/main.py <route-id> +14155550199 "United States"
```

`<route-id>`: the route to test. `<caller-id>`: the caller ID to present, in E.164 format. `<country>`: the route's destination country.

To try it without spending anything, run it against the [mock API](../../mock): start `node mock/server.mjs` from the repository root, then set `PACKETEXCHANGE_BASE_URL=http://127.0.0.1:4010/api/v1` and `PACKETEXCHANGE_API_KEY=wmmn_test_sk_mock`.

## API reference

- `GET /cli-tests/quota`
- `POST /cli-tests`
- `GET /cli-tests/{id}`

Full reference: [packetexchange.io/api-docs](https://packetexchange.io/api-docs)
