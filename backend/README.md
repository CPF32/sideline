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
                             add to la:sessions (KV)
Cron (*/5, game windows)────► group sessions by league
                             fetch each league once
                             (MFL liveScoring / Sleeper matchups)
                  ──APNs───► push each user's matchup
End activity      ──DELETE─► /v1/live-activity/:id
```

Cron runs **every 5 minutes, only during NFL game windows** (Sat/Sun afternoons, and the Thu/Sun/Mon night games that run past midnight UTC — see `wrangler.toml`). Outside those windows the Worker never wakes. Foreground app polling (~20s) still fills gaps while Sideline is open.

Each tick costs:

- **KV:** 1 read with no active sessions; otherwise 2 reads and at most 1 write (only when a score changed). All sessions live in `la:sessions` (written only by register/delete) and last-pushed content in `la:state` (written only by the cron). That keeps it well under the free tier's 1,000 writes/day.
- **Score APIs:** one fetch per active league/week, shared by every user in that league. MFL needs a login cookie, so the Worker uses any registered member's cookie for the whole league.
- **APNs:** one push per live user every tick, even if scores are unchanged, so the Live Activity's "next sync" countdown resets. Each push carries `nextSyncAt` (the next 5-minute boundary).

On the free plan a single run can make 50 outbound requests (league fetches + pushes), which limits how many users can have Live Activities running at once. Workers Paid raises that.

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

The cron schedule is already in `wrangler.toml` — after deploy, Cloudflare polls scores every 5 minutes during game windows.

## Privacy

- **Sleeper** sessions only send public league/roster IDs.
- **MFL** sessions send the `MFL_USER_ID` cookie for up to **8 hours** (Live Activity lifetime). It lives in Cloudflare KV, TTL’d, and is deleted when the activity ends. Prefer running the Worker on an account you control.

## Local test

```bash
npm run dev
curl -X POST http://127.0.0.1:8787/v1/live-activity/poll \
  -H "X-Sideline-Key: $REGISTER_SECRET"
```
