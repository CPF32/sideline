# Sideline Privacy Policy

**Last updated:** September 20, 2026

Sideline (“the app”) is a local-first iOS companion for MyFantasyLeague managers. This policy describes what information the app handles and how it is used.

## Summary

- Sideline is designed to keep your credentials and league data **on your device**.
- We do **not** operate a Sideline backend that stores your MFL password, LLM API keys, or roster data.
- Third-party services you connect (Apple, MyFantasyLeague, and your chosen LLM provider) process data under their own policies when the app talks to them.

## Information the app stores on your device

| Data | Where it lives | Purpose |
| --- | --- | --- |
| Sign in with Apple user ID and display name (optional) | Keychain / on-device | Sign you in locally |
| MyFantasyLeague username and session cookie | Keychain | Connect and sync your league |
| LLM API keys you paste in Settings | Keychain | Call the provider you select |
| Camera (optional) | Not stored | Scan an API key from a QR code or on-screen text; frames are not saved |
| Linked league / franchise metadata, proposals, chat threads, preferences | On-device (SwiftData / UserDefaults) | Run the team cockpit, agents, and approvals |

Deleting the app removes this on-device data (subject to any iCloud/device backups you enable).

## Information sent off your device

Only when **you** use a feature that requires it:

1. **Apple** — Sign in with Apple authentication (if you use that option).
2. **MyFantasyLeague** — Login, roster/league export, and writes you **approve** (lineups and other actions).
3. **Your LLM provider** (OpenAI, Anthropic, Google, OpenRouter, or another you configure) — prompts and tool context needed for agent runs and follow-up chat. Those requests use **your** API key and go to **that** provider.

Sideline does not sell personal information and does not use third-party advertising or analytics SDKs in the current app.

## How we use information

- Provide fantasy GM features (sync, agents, approvals).
- Authenticate with services you choose to connect.
- Keep API keys and session cookies out of the app binary and off any Sideline server.

## Sharing

We do not share your information with third parties except as needed for the services above that **you** connect. Those providers’ privacy policies apply to data they receive.

## Children

Sideline is not directed to children under 13. Do not use the app if you are under 13.

## Changes

We may update this policy as the app changes. The “Last updated” date at the top will change when we do. Continued use after an update means you accept the revised policy.

## Contact

Privacy questions: open an issue at [github.com/CPF32/sideline/issues](https://github.com/CPF32/sideline/issues).
