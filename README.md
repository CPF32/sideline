# Sideline

**Your fantasy GM desk — on your phone, under your control.**

Sideline is a local-first iOS app for MyFantasyLeague managers. Connect your league, sync your roster, and run specialist AI agents for lineup, waivers, and trades. Every write to MFL goes through an approval queue first — agents recommend; you decide.

![iOS 17+](https://img.shields.io/badge/iOS-17%2B-black) ![SwiftUI](https://img.shields.io/badge/SwiftUI-SwiftData-limegreen) ![MFL](https://img.shields.io/badge/MyFantasyLeague-API-brightgreen)

## What it does

- **Team cockpit** — Home is your franchise: starters, bench, taxi, salary/cap, and league context at a glance.
- **Specialist agents** — Lineup, Waiver, and Trade desks run only when you tap them. They use live MFL data (rosters, free agents, injuries, ranks, draft picks) plus optional LLM tool calls for follow-up chat.
- **Approve before write** — Nothing hits MFL until you explicitly approve. Local-first by design.
- **League-aware intel** — Positional strength vs the rest of the league, future draft picks, salary context, and research-backed player notes — not salary-only lists.
- **Your model, your key** — Bring OpenAI, Anthropic, Google, or OpenRouter. Keys stay on device (Keychain).

## Product rules

1. Home is the **team cockpit**
2. Agents run **only on tap**
3. **Nothing** writes to MFL until you **Approve**
4. Design: clean mist clipboard + sideline lime accent (light by default, dark supported)

## Stack

| Layer | Choice |
| --- | --- |
| UI | SwiftUI |
| Persistence | SwiftData |
| Auth | Sign in with Apple |
| League data | MyFantasyLeague + Sleeper |
| Session | MFL cookie / Sleeper ids in Keychain |
| LLMs | OpenAI · Anthropic · Google · OpenRouter |
| Live Activities | ActivityKit + optional Cloudflare Worker (`backend/`) pushing APNs |

## Project layout

```
sideline_ai/
├── Sideline/              # App sources
├── Shared/                # ActivityKit attributes (app + widget)
├── SidelineLiveActivity/  # Live Activity widget extension
├── backend/               # Cloudflare Worker — polls MFL/Sleeper, pushes APNs
├── Docs/                  # MFL notes + Live Activity backend
├── project.yml
└── Sideline.xcodeproj
```

Live Activity push backend: see [`backend/README.md`](backend/README.md).

## Setup

**Requirements:** macOS with Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen), iOS 17+ simulator or device.

```bash
cd sideline_ai
xcodegen generate
open Sideline.xcodeproj
```

1. Set your **Development Team** in Xcode signing.
2. Enable **Sign in with Apple** for the App ID if Xcode doesn’t auto-provision.
3. Register the MFL API User-Agent at [MFL API Client Registration](https://api.myfantasyleague.com/):

   `Sideline/1.0 (com.cpf32.sideline; iOS)`

4. In the app: **Settings** → paste an LLM API key → **Connect MFL** → **Sync**.

See [Docs/MFL.md](Docs/MFL.md) for caching, rate limits, and auth details.

## App Store screenshots

Raw simulator captures and connected marketing frames live under `AppStoreScreenshots/`.

```bash
./Scripts/capture_app_store_screenshots.sh              # build + capture + compose
./Scripts/capture_app_store_screenshots.sh --compose-only  # reframe existing raw PNGs
./Scripts/capture_app_store_screenshots.sh --raw-only      # capture only
```

- **Raw:** `AppStoreScreenshots/6.7-inch/` (1284×2778)
- **Marketing (upload these):** `AppStoreScreenshots/marketing/6.7-inch/` — mist/lime device frames and a lime ribbon that continues across the five-slide story (`Your desk.` → `The board.` → `On tap.` → `You approve.` → `Your model.`)
- **Preview strip:** `AppStoreScreenshots/marketing/6.7-inch/_series-preview.png` (do not upload)

Launch args for deterministic shots: `-ScreenshotDemo` and `-ScreenshotTab <team|league|agents|approvals|settings>`. Edit copy and layout in `Scripts/compose_marketing_screenshots.py`.

## Privacy & control

- API keys and MFL session cookies live in the **Keychain**, not in the repo.
- Agents propose actions; the **Approvals** queue is the only path to MFL writes.
- Sync and research stay scoped to the leagues you connect.

## About

Built by [Chris](https://github.com/CPF32) · Venmo `@CPF32`

---

*Sideline is an unofficial MyFantasyLeague companion. Not affiliated with MFL.*
