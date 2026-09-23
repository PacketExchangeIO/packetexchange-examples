# Search, buy and route a phone number (PHP)

Searches the number catalogue with `GET /dids/search`, buys a number with `POST /dids/buy`, and points its incoming calls at your SIP server or another phone number with `PATCH /dids/{id}/routing`.

## Cost

**Buying a number spends money.** `POST /dids/buy` charges the setup price plus the first month to your balance, and the number renews monthly while auto-renew is on. The example refuses to buy unless you pass `--confirm`. Searching and routing are free.

## Good to know

- A new number starts as `pending`; `number` is null until provisioning completes.
- Buying may require a verified identity where it is enforced (`403 KYC_REQUIRED`).
- `sip` routing takes `host[:port]` of your SIP server; `forward` takes an E.164 number. For ring groups and failover lists, use `PUT /dids/{id}/routing`.
- To be told about inbound activity by webhook, subscribe to `number.call.received` and `number.sms.received` in the dashboard and verify deliveries as in the [webhooks example](../webhooks).
- While the number store is unavailable these endpoints answer with `disabled: true` and a message; the example prints it.
- Scopes: `numbers:read` to search, `numbers:write` to buy and route.

## Run

From the `php` folder, with `PACKETEXCHANGE_API_KEY` set (see the [PHP README](../README.md) for setup):

```bash
php phone-numbers/index.php search 1415
php phone-numbers/index.php buy <groupId> <skuId>             # shows the cost warning and stops
php phone-numbers/index.php buy <groupId> <skuId> --confirm   # places the order and charges your balance
php phone-numbers/index.php route <didId> sip sip.example.com:5060
php phone-numbers/index.php route <didId> forward +14155550123
```

To try it without spending anything, run it against the [mock API](../../mock): start `node mock/server.mjs` from the repository root, then set `PACKETEXCHANGE_BASE_URL=http://127.0.0.1:4010/api/v1` and `PACKETEXCHANGE_API_KEY=wmmn_test_sk_mock`.

## API reference

- `GET /dids/search`
- `POST /dids/buy`
- `PATCH /dids/{id}/routing`

Full reference: [packetexchange.io/api-docs](https://packetexchange.io/api-docs)
