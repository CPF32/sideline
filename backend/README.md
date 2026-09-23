# Sideline Live Activity backend

Polls **MFL** / **Sleeper** live scores and pushes **ActivityKit** updates to APNs so Lock Screen / Dynamic Island stay fresh while the app is backgrounded.

FantasyPros is not used here (no live scoring API).

## Architecture

```
iOS app                     Cloudflare Worker                 Hosts
────────                    ─────────────────                 ─────
Start Live Activity
  pushType: .token
Observe pushToken  ──POST──► /v1/live-activity/register
                             store session in KV
Cron (* * * * *)  ─────────► fetch MFL liveScoring
                             or Sleeper matchups
                  ──APNs───► update content-state
End activity      ──DELETE─► /v1/live-activity/:id
```

Cron runs **every minute** (Cloudflare schedule minimum). That’s enough for football scoring cadence; foreground app polling (~20s) still fills gaps while Sideline is open.

## Apple setup (one-time)

1. Apple Developer → **Identifiers** → App ID `com.cpf32.sideline`
   - Enable **Push Notifications**
   - Enable **Live Activities** (Capability / Info.plist already set in app)
2. **Keys** → create an **APNs Auth Key** (.p8). Note **Key ID** + **Team ID**.
3. Download the `.p8` once; store as a Worker secret (never commit).

## Deploy (exact steps)

### 0. Prerequisites

- Node 18+ (`node -v`)
- A Cloudflare account
- Apple Developer: App ID `com.cpf32.sideline` with **Push Notifications** + **Live Activities**
- An **APNs Auth Key** (.p8) from Apple Developer → Keys — note **Key ID** and **Team ID**

### 1. Install + log in

```bash
cd /path/to/sideline_ai/backend
npm install
npx wrangler login
```

Browser opens → approve Cloudflare.

### 2. Create KV namespaces

```bash
npx wrangler kv namespace create SESSIONS
npx wrangler kv namespace create SESSIONS --preview
```

Each command prints an `id`. Open `wrangler.toml` and replace:

```toml
[[kv_namespaces]]
binding = "SESSIONS"
id = "PASTE_PRODUCTION_ID_HERE"
preview_id = "PASTE_PREVIEW_ID_HERE"
```

### 3. Fill Apple vars in `wrangler.toml`

```toml
[vars]
APNS_BUNDLE_ID = "com.cpf32.sideline"
APNS_TEAM_ID = "YOUR_10_CHAR_TEAM_ID"
APNS_KEY_ID = "YOUR_10_CHAR_KEY_ID"
```

APNs host is automatic: the app sends `sandbox` (DEBUG) or `production` (Release), and the Worker falls back to the other host if Apple rejects the token for the wrong environment. Do not set `APNS_HOST`.

### 4. Set secrets (not committed)

Generate a shared register secret (save it — you’ll paste into the iOS app):

```bash
openssl rand -hex 24
```

```bash
npx wrangler secret put REGISTER_SECRET
# paste the hex string, Enter

npx wrangler secret put APNS_PRIVATE_KEY
# paste the FULL contents of AuthKey_XXXX.p8 including
# -----BEGIN PRIVATE KEY----- and -----END PRIVATE KEY-----
# then Enter / Ctrl-D if prompted
```

### 5. Deploy

```bash
npx wrangler deploy
```

Wrangler prints a URL like:

`https://sideline-live.<your-subdomain>.workers.dev`

Smoke test:

```bash
curl https://sideline-live.<your-subdomain>.workers.dev/health
# {"ok":true,"service":"sideline-live"}
```

### 6. Wire the iOS app

Settings → **Appearance** → enable Matchup Live Activity, then:

- **Live backend URL** → the `https://…workers.dev` URL (no trailing slash)
- **Register secret** → same value as `REGISTER_SECRET`

Rebuild and run on a **physical iPhone** (Live Activities + push tokens need a device).

Cron (`* * * * *`) is already in `wrangler.toml` — Cloudflare will poll scores ~every minute after deploy.

## Privacy

- **Sleeper** sessions only send public league/roster IDs.
- **MFL** sessions send the `MFL_USER_ID` cookie for up to **8 hours** (Live Activity lifetime). It lives in Cloudflare KV, TTL’d, and is deleted when the activity ends. Prefer running the Worker on an account you control.

## Local test

```bash
npm run dev
curl -X POST http://127.0.0.1:8787/v1/live-activity/poll \
  -H "X-Sideline-Key: $REGISTER_SECRET"
```
