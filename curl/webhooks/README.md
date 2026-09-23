# Verify webhook signatures (curl)

curl cannot receive requests, so this folder has a command-line verifier instead of a server:
give it a captured delivery (the raw body saved to a file and the header values) and it checks
the signature with `openssl`. Every other language folder has a server version, for example
[Node.js](../../node/webhooks) or [Python](../../python/webhooks).

Each PacketExchange delivery is a JSON body `{ event, data, timestamp }` with these headers:

| Header | Value |
| --- | --- |
| `X-PX-Timestamp` | Unix seconds when this attempt was sent |
| `X-PX-Signature` | `v1=` + hex HMAC-SHA256 of `"<timestamp>.<raw body>"` with your endpoint's signing secret |
| `X-Webhook-Signature` | Legacy: `sha256=` + hex HMAC-SHA256 of the raw body |
| `X-Webhook-Event` | The event name, for example `sms.sent` |
| `X-Webhook-Id` | The delivery id |

How a receiver verifies a delivery (this script applies the same signature and timestamp checks to a saved delivery):

1. Read the **raw** body bytes and verify before parsing JSON. Re-serialised JSON will not match.
2. When `X-PX-Signature` is present, reject a timestamp more than 5 minutes from now, then compare
   the `v1` signature using a constant-time comparison.
3. Only when `X-PX-Signature` is absent, fall back to the legacy `X-Webhook-Signature`. The legacy
   scheme proves who sent a body but not when, so it cannot stop replays.
4. Answer `401` to anything that fails, and a quick `2xx` to anything that passes. Do slow work
   after responding or in a queue, so the delivery is not timed out and retried.

## Cost

Free. Receiving webhooks costs nothing.

## Set up

Create a webhook endpoint in the [dashboard](https://packetexchange.io/dashboard), or with `POST /account/webhooks` using an API key created with the `webhooks:write` permission (a full-access key does not include it). Choose its events (for example `sms.delivered`, `call.completed`, `number.sms.received`) and copy the signing secret, which is shown once. Endpoint URLs must be `https` and publicly reachable; during development, expose your local server through a tunnel.

## Run

From the `curl` folder (see the [curl README](../README.md) for setup):

```bash
export PACKETEXCHANGE_WEBHOOK_SECRET=...   # shown once when you create the endpoint
./webhooks/example.sh body.json "<X-PX-Timestamp>" "<X-PX-Signature>"
./webhooks/example.sh --legacy body.json "<X-Webhook-Signature>"
```

To try it locally, `node ../mock/send-webhook.mjs --emit-dir /tmp/delivery` writes a freshly signed delivery to files.

## API reference

Full reference: [packetexchange.io/api-docs](https://packetexchange.io/api-docs)
