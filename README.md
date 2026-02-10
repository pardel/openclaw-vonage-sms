# Vonage SMS Skill

SMS-based conversations with your agent via the Vonage Messages API. Vonage handles SMS delivery; the agent responds through OpenClaw's chat completions endpoint.

```
SMS → Vonage → Express webhook server → OpenClaw gateway → Agent
```

## Setup

See [SKILL.md](SKILL.md) for full setup instructions, configuration, and troubleshooting.

## Files

| File | Purpose |
|------|---------|
| `SKILL.md` | Detailed setup, configuration, and troubleshooting guide |
| `scripts/setup.sh` | Scaffolds the webhook server project |
| `references/vonage-messages-api.md` | Vonage Messages API reference |
