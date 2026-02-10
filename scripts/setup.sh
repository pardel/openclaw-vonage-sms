#!/usr/bin/env bash
set -euo pipefail

# Usage: scripts/setup.sh <target-directory>
# Creates a Vonage SMS webhook server project using the Messages API.

TARGET="${1:?Usage: setup.sh <target-directory>}"

if [ -d "$TARGET/node_modules" ]; then
  echo "[skip] $TARGET already has node_modules — run 'node server.js' to start"
  exit 0
fi

mkdir -p "$TARGET"

# ── package.json ─────────────────────────────────────────────────────────
cat > "$TARGET/package.json" << 'PACKAGE_EOF'
{
  "name": "vonage-sms",
  "version": "1.0.0",
  "description": "Vonage SMS webhook server for OpenClaw (Messages API)",
  "main": "server.js",
  "scripts": { "start": "node server.js" },
  "dependencies": { "express": "^4.18.0" }
}
PACKAGE_EOF

# ── .env template ────────────────────────────────────────────────────────
if [ ! -f "$TARGET/.env" ]; then
cat > "$TARGET/.env" << 'ENV_EOF'
VONAGE_APP_ID=__SET_ME__
VONAGE_PRIVATE_KEY_PATH=./private.key
VONAGE_NUMBER=__SET_ME__
PORT=3001
OPENCLAW_GATEWAY_URL=http://127.0.0.1:18789
OPENCLAW_GATEWAY_TOKEN=__SET_ME__
ENV_EOF
  echo "[created] $TARGET/.env — edit with your credentials"
else
  echo "[skip] $TARGET/.env already exists"
fi

# ── .gitignore ───────────────────────────────────────────────────────────
cat > "$TARGET/.gitignore" << 'GIT_EOF'
node_modules/
.env
private.key
sms.log
GIT_EOF

# ── server.js ────────────────────────────────────────────────────────────
cat > "$TARGET/server.js" << 'SERVER_EOF'
const express = require('express');
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// ── Load .env ───────────────────────────────────────────────────────────
const envPath = path.join(__dirname, '.env');
if (fs.existsSync(envPath)) {
  for (const line of fs.readFileSync(envPath, 'utf8').split('\n')) {
    const m = line.match(/^\s*([^#=]+?)\s*=\s*(.*)\s*$/);
    if (m && !process.env[m[1]]) process.env[m[1]] = m[2];
  }
}

const PORT = parseInt(process.env.PORT || '3001', 10);
const VONAGE_APP_ID = process.env.VONAGE_APP_ID;
const VONAGE_PRIVATE_KEY = fs.readFileSync(
  path.resolve(__dirname, process.env.VONAGE_PRIVATE_KEY_PATH || './private.key'),
  'utf8'
);
const VONAGE_NUMBER = process.env.VONAGE_NUMBER;
const OPENCLAW_URL = process.env.OPENCLAW_GATEWAY_URL || 'http://127.0.0.1:18789';
const OPENCLAW_TOKEN = process.env.OPENCLAW_GATEWAY_TOKEN;

const app = express();
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

// ── Logging ─────────────────────────────────────────────────────────────
const LOG_FILE = path.join(__dirname, 'sms.log');

function log(tag, ...args) {
  const ts = new Date().toISOString();
  const msg = args.map(a => typeof a === 'string' ? a : JSON.stringify(a)).join(' ');
  const line = `[${ts}] [${tag}] ${msg}`;
  console.log(line);
  fs.appendFileSync(LOG_FILE, line + '\n');
}

// ── JWT generation ──────────────────────────────────────────────────────
function generateJwt() {
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: 'RS256', typ: 'JWT' };
  const payload = {
    application_id: VONAGE_APP_ID,
    iat: now,
    jti: crypto.randomUUID(),
    exp: now + 900,
  };
  const enc = (obj) => Buffer.from(JSON.stringify(obj)).toString('base64url');
  const unsigned = `${enc(header)}.${enc(payload)}`;
  const signature = crypto.sign('RSA-SHA256', Buffer.from(unsigned), VONAGE_PRIVATE_KEY);
  return `${unsigned}.${signature.toString('base64url')}`;
}

// ── Conversation state (in-memory) ─────────────────────────────────────
const conversations = new Map();

setInterval(() => {
  const cutoff = Date.now() - 7200_000;
  for (const [num, conv] of conversations) {
    if (conv.updatedAt < cutoff) conversations.delete(num);
  }
}, 600_000);

// ── OpenClaw integration ────────────────────────────────────────────────
async function askClaw(phoneNumber, userText) {
  let conv = conversations.get(phoneNumber);
  if (!conv) {
    conv = {
      messages: [
        {
          role: 'system',
          content:
            'You are responding via SMS. Keep responses concise — SMS has a 140 character limit per segment, so aim for short, clear replies. No markdown. Be conversational but brief.',
        },
      ],
      updatedAt: Date.now(),
    };
    conversations.set(phoneNumber, conv);
  }

  conv.messages.push({ role: 'user', content: userText });
  conv.updatedAt = Date.now();

  log('CLAW-REQ', `from=${phoneNumber} text="${userText}" messages=${conv.messages.length}`);

  const startMs = Date.now();
  const res = await fetch(`${OPENCLAW_URL}/v1/chat/completions`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${OPENCLAW_TOKEN}`,
    },
    body: JSON.stringify({ model: 'openclaw', messages: conv.messages }),
  });

  const elapsed = Date.now() - startMs;

  if (!res.ok) {
    const body = await res.text();
    log('CLAW-ERR', `status=${res.status} elapsed=${elapsed}ms body=${body}`);
    return "Sorry, having trouble right now. Try again shortly.";
  }

  const data = await res.json();
  const reply = data.choices?.[0]?.message?.content || "Sorry, something went wrong.";
  conv.messages.push({ role: 'assistant', content: reply });
  log('CLAW-REPLY', `from=${phoneNumber} elapsed=${elapsed}ms reply="${reply}"`);
  return reply;
}

// ── Send SMS via Messages API ───────────────────────────────────────────
async function sendSms(to, text) {
  log('SMS-SEND', `to=${to} text="${text}"`);

  const jwt = generateJwt();
  const res = await fetch('https://api.nexmo.com/v1/messages', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${jwt}`,
    },
    body: JSON.stringify({
      message_type: 'text',
      text,
      to,
      from: VONAGE_NUMBER,
      channel: 'sms',
    }),
  });

  if (!res.ok) {
    const body = await res.text();
    log('SMS-ERR', `to=${to} status=${res.status} body=${body}`);
    return false;
  }

  const data = await res.json();
  log('SMS-OK', `to=${to} messageId=${data.message_uuid}`);
  return true;
}

// ── Webhooks ────────────────────────────────────────────────────────────
async function handleInbound(params) {
  const from = params.from || params.msisdn;
  const text = params.text;

  if (!from || !text) {
    log('INBOUND-SKIP', 'Missing from or text');
    return;
  }

  log('INBOUND', `from=${from} text="${text}"`);

  try {
    const reply = await askClaw(from, text);
    await sendSms(from, reply);
  } catch (err) {
    log('ERROR', `from=${from} ${err.message}`);
    await sendSms(from, "Sorry, something went wrong.").catch(() => {});
  }
}

app.post('/webhooks/inbound', async (req, res) => {
  log('INBOUND-RAW', req.body);
  res.status(200).end();
  await handleInbound(req.body);
});

app.get('/webhooks/inbound', async (req, res) => {
  log('INBOUND-RAW', req.query);
  res.status(200).end();
  await handleInbound(req.query);
});

app.post('/webhooks/status', (req, res) => {
  log('STATUS', `messageId=${req.body.message_uuid} status=${req.body.status}`);
  res.status(200).end();
});

// ── Proactive send endpoint ─────────────────────────────────────────────
app.post('/send', async (req, res) => {
  const { to, text } = req.body;
  if (!to || !text) return res.status(400).json({ error: 'to and text required' });
  const ok = await sendSms(to, text);
  res.json({ ok });
});

app.get('/health', (req, res) => {
  res.json({ status: 'ok', conversations: conversations.size });
});

// ── Start ───────────────────────────────────────────────────────────────
app.listen(PORT, '0.0.0.0', () => {
  log('START', `SMS server listening on port ${PORT}`);
  log('START', `Vonage number: ${VONAGE_NUMBER}`);
  log('START', `Vonage app: ${VONAGE_APP_ID}`);
  log('START', `OpenClaw: ${OPENCLAW_URL}`);
});
SERVER_EOF

# ── Install dependencies ─────────────────────────────────────────────────
cd "$TARGET" && npm install

echo ""
echo "✅ Vonage SMS server created at $TARGET"
echo ""
echo "Next steps:"
echo "  1. Edit $TARGET/.env with your credentials"
echo "  2. Place your Vonage private key at $TARGET/private.key"
echo "  3. Enable Messages capability on your Vonage app"
echo "  4. Set Default SMS Setting to 'Messages API' in Vonage Dashboard"
echo "  5. Set inbound webhook URL in Vonage app"
echo "  6. Run: cd $TARGET && node server.js"
