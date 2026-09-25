# Sideline Privacy Policy

**Last updated:** September 24, 2026

Sideline (“the app”) is a local-first iOS companion for MyFantasyLeague and Sleeper managers. This policy describes what information the app handles and how it is used.

## Summary

- Sideline is designed to keep your credentials and private league data **on your device**.
- Optional **Sideline Cloudflare Workers** power Live Activity push and a **shared public data cache** (NFL schedule, Sleeper public catalogs/state/matchups, DynastyProcess player IDs). Those Workers do **not** store your MFL password, FantasyPros / Odds / LLM API keys, or private roster exports.
- Third-party services you connect (Apple, MyFantasyLeague, Sleeper, and your chosen LLM / intel providers) process data under their own policies when the app talks to them.

## Information the app stores on your device

| Data | Where it lives | Purpose |
| --- | --- | --- |
| Sign in with Apple user ID and display name (optional) | Keychain / on-device | Sign you in locally |
| MyFantasyLeague username and session cookie | Keychain | Connect and sync your league |
| Sleeper username / user id | Keychain | Connect and sync Sleeper leagues |
| LLM, FantasyPros, and Odds API keys you paste in Settings | Keychain | Call the provider you select (BYOK) |
| Camera (optional) | Not stored | Scan an API key from a QR code or on-screen text; frames are not saved |
| Linked league / franchise metadata, proposals, chat threads, preferences | On-device (SwiftData / UserDefaults) | Run the team cockpit, agents, and approvals |
| HTTP response cache for public + league fetches | On-device cache | Faster loads without re-hitting the network |

Deleting the app removes this on-device data (subject to any iCloud/device backups you enable).

## Information sent off your device

Only when **you** use a feature that requires it:

1. **Apple** — Sign in with Apple authentication (if you use that option).
2. **MyFantasyLeague** — Login, roster/league export, and writes you **approve** (lineups and other actions).
3. **Sleeper** — Public league/roster APIs for leagues you connect.
4. **Your LLM / FantasyPros / Odds providers** — requests use **your** API keys and go to **those** providers from the device (not through Sideline’s public cache).
5. **Sideline Live Activity Worker** (optional) — push token and matchup context so Lock Screen scores update while the app is backgrounded. For MFL, this may include a short-lived session cookie (up to ~8 hours) while a Live Activity is active.
6. **Sideline public cache Worker** — the app may fetch shared public blobs (schedule, catalogs, public matchups) from Sideline instead of directly from upstream. Responses are the same public data; no credentials are sent on these requests.

Sideline does not sell personal information and does not use third-party advertising or analytics SDKs in the current app.

## How we use information

- Provide fantasy GM features (sync, agents, approvals, Live Activities).
- Authenticate with services you choose to connect.
- Cache public sports/fantasy metadata at the edge to improve performance and reduce upstream load.
- Keep API keys and long-lived session cookies out of the app binary; commercial keys stay on-device.

## Sharing

We do not share your information with third parties except as needed for the services above that **you** connect. Those providers’ privacy policies apply to data they receive.

## Children

Sideline is not directed to children under 13. Do not use the app if you are under 13.

## Changes

We may update this policy as the app changes. The “Last updated” date at the top will change when we do. Continued use after an update means you accept the revised policy.

## Contact

Privacy questions: open an issue at [github.com/CPF32/sideline/issues](https://github.com/CPF32/sideline/issues).
