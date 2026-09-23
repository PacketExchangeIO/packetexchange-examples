# Create an AI voice agent (Java)

Picks a voice with `GET /ai-agents/voices`, creates an agent with `POST /ai-agents` (an appointment-confirmation script with guardrails), tries one conversation turn in text with `POST /ai-agents/{id}/simulate`, and, when you pass a campaign id, attaches the agent to that voice campaign with `PUT /dialer/campaigns/{id}` so it handles the answered calls.

## Cost

Creating, editing and simulating an agent is not billed. Calls an agent handles are billed per AI-connected minute; `maxCallSeconds` caps the length, and so the cost, of each call.

## Good to know

- Agents run on **outbound voice campaigns**. They are attached to a campaign, not to a phone number, and the campaign must be a draft, ready or paused.
- Only call people who have agreed to receive the call, such as customers confirming a booking.
- Scoped API keys need the `dialer:write` scope.

## Run

From the `java` folder, with `PACKETEXCHANGE_API_KEY` set (see the [Java README](../README.md) for setup):

```bash
java -cp 'target/dependency/*' ai-voice-agent/Main.java
```

`[campaign-id]`: optional; the voice campaign to attach the agent to.

To try it without spending anything, run it against the [mock API](../../mock): start `node mock/server.mjs` from the repository root, then set `PACKETEXCHANGE_BASE_URL=http://127.0.0.1:4010/api/v1` and `PACKETEXCHANGE_API_KEY=wmmn_test_sk_mock`.

## API reference

- `GET /ai-agents/voices`
- `POST /ai-agents`
- `POST /ai-agents/{id}/simulate`
- `PUT /dialer/campaigns/{id}`

Full reference: [packetexchange.io/api-docs](https://packetexchange.io/api-docs)
