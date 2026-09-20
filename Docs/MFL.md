# MFL API client notes

## User-Agent (required for higher limits)

Every request sends:

```
Sideline/1.0 (com.cpf32.sideline; iOS)
```

Defined in `MFLClient.userAgent`.

Register this exact string at MyFantasyLeague → API Client Registration (validate via SMS), then MFL can raise per-IP limits (~2.5×).

## Caching & rate limits

- Player list TTL: 24h
- League rules: 10m
- Rosters: 60s
- Projections / schedule / FA: 3–5m
- Minimum ~1.1s between requests
- HTTP 429 → `MFLError.rateLimited` (no automatic retry storm)

## Auth

- Login: HTTPS POST `api.myfantasyleague.com/{season}/login`
- Session: `MFL_USER_ID` cookie in Keychain
- Writes (`import`) require that owner cookie; league `APIKEY` is export-only
- Lineup import: `GET /{season}/import?TYPE=lineup&L=&W=&STARTERS=` on the league host
- `FRANCHISE_ID` is only for commissioners impersonating a franchise — owners omit it

## Why Approve might not change the MFL app

1. Sideline must be connected with your **MFL website password** (Settings → Connect MFL), not just Apple Sign In.
2. Approve only writes when the proposal is auto-settable (Approve button visible). “Can’t auto-set” proposals do not call MFL.
3. The MFL iOS app is a separate client — pull to refresh after Sideline reports applied; check the **same week**.
4. Expired session → reconnect MFL in Sideline.