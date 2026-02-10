---
name: vonage-sms
description: >
  Set up SMS conversations with the agent via Vonage Messages API. Send and receive
  text messages through a Vonage number, with the agent responding conversationally.
  Use when the user wants to text the agent, set up SMS messaging, configure Vonage
  Messages webhooks, or troubleshoot SMS delivery issues.
---

# Vonage SMS

SMS-based conversational interface using Vonage Messages API.

## Architecture

```
SMS → Vonage → Express webhook server (POST /webhooks/inbound)
                ├── Text → OpenClaw chat API → response
                └── Response → Vonage Messages API → SMS reply
```

Uses JWT auth (application ID + private key), same credentials as Vonage Voice.

## Setup Steps

### 1. Vonage Account & Application

1. Create a [Vonage account](https://dashboard.vonage.com)
2. Create or reuse a Vonage Application — enable the **Messages** capability
3. Rent a Voice/SMS-enabled number and link it to the application
4. In Dashboard → Settings → **set Default SMS Setting to "Messages API"**

### 2. OpenClaw Gateway

Enable the chat completions endpoint:

```json
{ "gateway": { "http": { "endpoints": { "chatCompletions": { "enabled": true } } } } }
```

### 3. Deploy the Server

Run the setup script:

```bash
scripts/setup.sh ~/code/vonage-sms
```

Then configure `~/code/vonage-sms/.env`:

```
VONAGE_APP_ID=<your application id>
VONAGE_PRIVATE_KEY_PATH=./private.key
VONAGE_NUMBER=<your vonage number, no + prefix>
PORT=3001
OPENCLAW_GATEWAY_URL=http://127.0.0.1:18789
OPENCLAW_GATEWAY_TOKEN=<your gateway token>
```

Place your Vonage private key at `~/code/vonage-sms/private.key`.

### 4. Configure Vonage Webhooks

In the Vonage Dashboard → Application → Messages capability:

- **Inbound URL:** `http://<your-ip>:3001/webhooks/inbound`
- **Status URL:** `http://<your-ip>:3001/webhooks/status`

### 5. Firewall

```bash
sudo ufw allow 3001/tcp
```

### 6. Start

```bash
cd ~/code/vonage-sms && node server.js
```

Health check: `curl http://localhost:3001/health`

## Sending a Proactive SMS

The server includes a `/send` endpoint for outbound messages:

```bash
curl -X POST http://localhost:3001/send \
  -H 'Content-Type: application/json' \
  -d '{"to": "<recipient_number>", "text": "Hey from OpenClaw!"}'
```

## Conversation State

- Conversations are keyed by phone number
- History is kept in-memory for 2 hours of inactivity, then cleared
- System prompt instructs the agent to keep replies SMS-short (~140 chars)

## Troubleshooting

- **No inbound messages**: Check that "Default SMS Setting" is set to "Messages API" (not SMS API) in Dashboard → Settings
- **Number not receiving**: Ensure the number is linked to the application with Messages capability
- **Auth errors on send**: Verify private key matches the application
- **Webhook not reached**: Check firewall and that the inbound URL is correct

## Logs

Server logs to stdout and `sms.log`:

| Tag | Meaning |
|-----|---------|
| `INBOUND` | Received SMS |
| `INBOUND-RAW` | Full Vonage payload |
| `CLAW-REQ` | Request to OpenClaw |
| `CLAW-REPLY` | Response from OpenClaw (with latency) |
| `SMS-SEND` | Sending reply |
| `SMS-OK` | Reply sent successfully |
| `SMS-ERR` | Send failure |
| `STATUS` | Delivery receipt |

## References

- See [references/vonage-messages-api.md](references/vonage-messages-api.md) for API reference
