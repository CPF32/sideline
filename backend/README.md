# Sideline Live + Public Cache backend

Cloudflare Worker that:

1. **Live Activities** — polls MFL / Sleeper live scores and pushes ActivityKit updates via APNs.
2. **Shared public cache** — serves NFL schedule, Sleeper nflState / players / public matchups, and DynastyProcess player IDs from **CACHE KV** (hot JSON) + **R2** (large catalogs) so devices hit Sideline first instead of slamming upstream on every cold launch.

FantasyPros and The Odds API are **BYOK** (bring your own key). Keys stay on-device and are sent only as `X-Vendor-API-Key` on cache miss so the Worker can fetch upstream. Responses are cached **per Apple user** in CACHE KV (`byok:*`) — never shared across users. This is distinct from a future shared “pro mode” Sideline key.

Private league sync (auth’d MFL / Sleeper / ESPN rosters) stays device → vendor.

## Architecture

```
iOS app                         Cloudflare Worker                    Upstream
────────                        ─────────────────                    ────────
DataCache L1 ──miss──GET──────► /v1/public/* ──HIT──► CACHE KV / R2
                              │                MISS / ?revalidate=1
                              └──────────────────────► Sleeper / MFL public / GitHub

DataCache L1 ──miss──GET──────► /v1/byok/fantasypros/*  ──HIT──► CACHE byok:fp:…
  + X-Sideline-Key              │                      MISS
  + X-Sideline-User-Id          └──────────────────────► FantasyPros (user’s x-api-key)
  + X-Vendor-API-Key

DataCache L1 ──miss──GET──────► /v1/byok/odds/*  ──HIT──► CACHE byok:odds:…
  + same auth headers           └──────────────────────► The Odds API (user’s apiKey)

Live Activity register ──POST─► /v1/live-activity/* ──► SESSIONS KV + APNs
```

### Public endpoints (no auth)

| Route | Source | Storage |
| --- | --- | --- |
| `GET /v1/public/nfl-schedule?season=&week=` | MFL `TYPE=nflSchedule` | CACHE KV |
| `GET /v1/public/sleeper/nfl-state` | Sleeper `/state/nfl` | CACHE KV |
| `GET /v1/public/sleeper/matchups?leagueId=&week=` | Sleeper matchups | CACHE KV (+ watched set for cron) |
| `GET /v1/public/sleeper/players` | Sleeper `/players/nfl` (~15MB) | R2 `catalogs/sleeper-players-nfl.json` |
| `GET /v1/public/mfl/player-intel?season=&ids=` | MFL `playerProfile` (bio + news articles) + `players&DETAILS` | CACHE KV per player id |

### Per-user BYOK cache (auth required)

| Route | Source | Storage | TTL |
| --- | --- | --- | --- |
| `GET /v1/byok/fantasypros/<path>?…` | FantasyPros public v2 JSON | `byok:fantasypros:{userHash}:{keyFp}:{pathHash}` | 1h |
| `GET /v1/byok/odds/<path>?…` | The Odds API v4 | `byok:odds:{userHash}:{keyFp}:{pathHash}` | events/props 1h; live props 60s (`X-Sideline-Live: 1`); historic 1d |

Headers: `X-Sideline-Key` (REGISTER_SECRET), `X-Sideline-User-Id` (Apple user id), `X-Vendor-API-Key` (user’s FantasyPros or Odds key). Vendor keys are **never** written to KV.

Query `?revalidate=1` (or `Cache-Control: no-cache`) forces an upstream refill. Responses include `ETag`, `Cache-Control`, and `X-Sideline-Cache: HIT|MISS|REVALIDATED|HIT-WAIT`.

Cold keys use a short KV lock so concurrent devices single-flight the upstream fetch.

### Refresh paths

| Path | Behavior |
| --- | --- |
| Cron (game windows) | Refreshes nflState, current week schedule, watched matchups; also runs Live Activity poll |
| Cron `0 10 * * *` | Daily catalog refresh (players + player-ids) |
| On-demand | First request / TTL miss fills from upstream |
| App pull-to-refresh | iOS clears L2 and calls with `revalidate=1` |
| Worker down | iOS falls back to vendor URLs directly |

Manual: `POST /v1/public/refresh?catalogs=1` with `X-Sideline-Key` (same as Live Activity secret).

## Storage

| Binding | Role |
| --- | --- |
| `SESSIONS` | Live Activity sessions + last-pushed state (`la:*`) |
| `CACHE` | Hot public JSON (`pub:*` schedule, state, matchups, ETag meta, locks) |
| `PUBLIC` (R2 bucket `sideline-public`) | Large catalogs (`catalogs/sleeper-players-nfl.json`, `catalogs/db_playerids.csv`) |

```toml
[[r2_buckets]]
binding = "PUBLIC"
bucket_name = "sideline-public"
preview_bucket_name = "sideline-public"
```

**Workers Paid** is assumed for KV write headroom and cron volume.

## Live Activity (unchanged)

```
Start Live Activity
  pushType: .token
Observe pushToken  ──POST──► /v1/live-activity/register
                             add to la:sessions (SESSIONS KV)
Cron (*/5, game windows)────► group sessions by league
                             fetch each league once
                  ──APNs───► push each user's matchup
End activity      ──DELETE─► /v1/live-activity/:id
```

Cron runs every 5 minutes during NFL game windows (see `wrangler.toml`), plus the daily catalog tick.

Each Live Activity tick costs:

- **SESSIONS KV:** 1 read with no active sessions; otherwise 2 reads and at most 1 write (only when a score changed).
- **Score APIs:** one fetch per active league/week, shared by every user in that league.
- **APNs:** one push per live user every tick.

## Apple setup (one-time)

1. Apple Developer → **Identifiers** → App ID `com.cpf32.sideline`
   - Enable **Push Notifications**
   - Enable **Live Activities** (Capability / Info.plist already set in app)
2. **Keys** → create an **APNs Auth Key** (.p8). Note **Key ID** + **Team ID**.
3. Download the `.p8` once; store as a Worker secret (never commit).

## Deploy

### 0. Prerequisites

- Node 18+ (`node -v`)
- A Cloudflare account (Workers Paid recommended)
- Apple Developer: App ID with **Push Notifications** + **Live Activities**
- An **APNs Auth Key** (.p8)

### 1. Install + log in

```bash
cd backend
npm install
npx wrangler login
```

### 2. KV (already created for this project)

```toml
[[kv_namespaces]]
binding = "SESSIONS"
id = "…"
preview_id = "…"

[[kv_namespaces]]
binding = "CACHE"
id = "…"
preview_id = "…"
```

To recreate:

```bash
npx wrangler kv namespace create CACHE
npx wrangler kv namespace create CACHE --preview
```

### 3. Apple vars + secrets

```toml
[vars]
APNS_BUNDLE_ID = "com.cpf32.sideline"
APNS_TEAM_ID = "YOUR_10_CHAR_TEAM_ID"
APNS_KEY_ID = "YOUR_10_CHAR_KEY_ID"
```

```bash
openssl rand -hex 24
npx wrangler secret put REGISTER_SECRET
npx wrangler secret put APNS_PRIVATE_KEY
```

### 4. Deploy

```bash
npx wrangler deploy
```

Smoke test:

```bash
curl https://sideline-live.<subdomain>.workers.dev/health
# {"ok":true,"service":"sideline-live","publicCache":true,"r2":false}

curl -D - "https://sideline-live.<subdomain>.workers.dev/v1/public/sleeper/nfl-state" -o /dev/null
# X-Sideline-Cache: MISS then HIT on second request
```

### 5. Wire the iOS app

Settings → Live Activity backend URL (defaults to the deployed Worker). Public cache uses the **same base URL** via `SidelinePublicClient`.

## Privacy

- **Public cache** stores only public upstream blobs (schedule, Sleeper catalogs/state/matchups, DynastyProcess IDs). No user API keys, no MFL passwords.
- **Sleeper** Live Activity sessions only send public league/roster IDs.
- **MFL** Live Activity sessions send the `MFL_USER_ID` cookie for up to **8 hours** (Live Activity lifetime) in `SESSIONS` KV, TTL’d, deleted when the activity ends.
- **BYOK (FantasyPros / Odds)** — user keys are sent as `X-Vendor-API-Key` only on Worker cache miss so the Worker can call the vendor. Keys are **not** stored in KV; cached bodies are keyed by hashed user id + key fingerprint (`byok:*`) and never shared across users. LLM keys stay on-device only.
- Future **pro mode** (Sideline-owned shared key) will use a separate `pro:*` cache namespace — not this BYOK path.

## Measuring impact

Before: each cold launch / first sync could hit MFL public schedule + Sleeper `/players/nfl` (~15MB) + DynastyProcess CSV + nflState independently per device.

After: those requests go to the Worker; N devices share one upstream fill. Check `X-Sideline-Cache: HIT` on repeat GETs. Device `DataCache` still short-circuits network when L2 is warm.

## Local test

```bash
npm run dev
curl http://127.0.0.1:8787/v1/public/sleeper/nfl-state
curl -X POST http://127.0.0.1:8787/v1/live-activity/poll \
  -H "X-Sideline-Key: $REGISTER_SECRET"
```
