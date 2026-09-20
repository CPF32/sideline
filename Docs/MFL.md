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
- Writes (`import`) require cookie; league `APIKEY` is export-only
