<div align="center">

<img src="assets/branding/lmstory_logo_v1.png" alt="LMStory Logo" width="180" height="180">

# LMStory

**A world isn't defined in advance. It takes shape through what you experience.**

A local-first interactive world: you advance, AI responds, and every experience becomes part of its knowledge and history.

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-%3E%3D3.19-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Platform](https://img.shields.io/badge/Platform-Android%20%7C%20iOS%20%7C%20macOS%20%7C%20Windows%20%7C%20Linux%20%7C%20Web-green)](#platform-support)

English · [中文](README.md)

</div>

Not an AI companion. Not a novel generator. More than roleplay —

**LMStory is a world narrative engine.**

You advance. AI responds. The world grows: no character card, lorebook, or plot outline required. Start with a single sentence — the people you meet, the choices you make, and the things that happen settle into this world's knowledge and history, shaping everything that comes after.

## How LMStory differs from three familiar products

| Product | Core object | Primary goal |
|---|---|---|
| Companion apps | One preset character | Building a relationship with it |
| AI taverns / role-play frontends | Pre-configured characters & worlds | Acting out preset scenarios |
| Novel generators / writing assistants | Outline & chapters | Producing a finished text |
| **LMStory** | **A world that keeps forming** | **Exploring and changing it yourself** |

- **Character cards and lorebooks are seeds, not tickets.** LMStory imports SillyTavern-compatible character cards and lorebooks (with more formats planned), but you can bring nothing at all and start from zero.
- **Memory is not chat history — it's the world's past.** The world doesn't just hold what was written down; it accumulates history that actually happened.
- **The novel is not the goal — it's a memento of the journey.** Single-session manuscripts can already be exported as Markdown keepsakes; cross-session journey archival, chronicles, and sharing remain planned — export is a keepsake, not the point of playing.

## How the world grows

Every round, LMStory performs an invisible act of "worldkeeping":

1. **You advance** — write your actions, dialogue, and choices;
2. **AI responds** — the world reacts: characters have memory and standing, events have consequences;
3. **Experiences settle** — what happened this round, which facts changed, which relationships shifted, are organized into the world's memory;
4. **The future inherits the world** — the next round builds on the world's entire history: established facts aren't forgotten without cause, and setting drift is corrected by the world itself.

All of this happens on your device (see [Data & Privacy](#data--privacy-local-first)), powered by the AI model you bring (see [Getting Started](#getting-started)).

## Currently implemented

| Capability | Status | Notes |
|---|---|---|
| **Chat mode** | ✅ Implemented | General AI chat: multi-provider, streaming, branches, attachments, context compaction |
| **Story mode** | ✅ Implemented | Immersive narration: experiential and factual memory accumulate every round; past events and settings are retrieved before writing; optional review stage; failure recovery. Regenerating snapshots the old draft as a switchable variant and interrupted prose is never lost; manuscripts export to Markdown, plus in-session search and reading-position memory |
| **Director mode** | ✅ Implemented | You write the project rules; an AI "chief editor" runs the world backstage — retrieving memories, maintaining settings, and writing the prose. Includes watch mode (approve every write), ask-the-director prompts, layered process view, durable event log & crash recovery. Enable it in Settings |
| **Lorebook / character cards (library)** | ✅ Implemented | Import SillyTavern-compatible PNG character cards (V1/V2/V3), plain JSON cards, and lorebook JSON; apply to a session as read-only "seed" settings; **AI card builder**: co-create cards and lorebooks through an agent conversation, saved after draft confirmation |
| **BYOK** | ✅ Implemented | 7 built-in provider templates (OpenAI / DeepSeek / OpenRouter / Anthropic Claude / Google Gemini / NVIDIA NIM / Agnes AI); OpenAI-compatible, Anthropic, and Gemini protocols |
| **Data import/export** | ✅ Implemented | Sessions, memories, and settings; local-first |
| **UI language** | ✅ Implemented | Simplified Chinese / English, switchable in Settings → Language and input (instant, remembered; follow-system not yet available) |

**Planned** (not delivered; never presented as implemented): follow-system language · journey archival / chronicle export (single-session manuscript export already implemented) · CHARX card format · official Web release.

## Start from zero, or bring seeds

**From zero**: create a story session and write your first line — "Rainy night. The old house's door knocks a third time." The world starts forming from your first sentence.

**With seeds**: Settings → Character cards / Lorebooks, import your existing SillyTavern-compatible assets, then apply them in the story session's settings. Imported settings join the world as a read-only baseline; new facts the world learns still accumulate normally, growing alongside your seeds.

Want the other way to play? Enable **Director mode** in Settings, write your project rules, and let the AI chief editor run the world while you supervise.

## Getting started

The project is in open-source preparation; no release binaries yet — build from source:

```bash
git clone https://github.com/snanjib/LMStory.git
cd LMStory

dart pub get
dart run build_runner build --delete-conflicting-outputs
dart run slang        # i18n codegen
flutter run
```

Requirements: Flutter >= 3.19, Dart >= 3.3. After first launch, go to **Settings → General → Providers**: pick a template (or custom) → enter `baseUrl` and API key → choose a model.

## Data & privacy: local-first

- Sessions, memories, and world facts live entirely in an **on-device database**; nothing is uploaded;
- API keys are kept in platform secure storage; LLM requests go only to **providers you configure**;
- No cloud accounts, telemetry, or ads.

## Development status & platform support

| Platform | Status | Notes |
|---|---|---|
| Android | ⚠️ In development | Primary target; production signing chain in place (release keystore + CI injection) |
| iOS / macOS | ✅ Adapted | v0.4.1 ships dual-platform adaptation (drag & drop, close-window guard, keychain authorization memory); no store distribution yet |
| Windows / Linux | ⚠️ Unvalidated | Platform projects exist; no release validation yet |
| Web | ⚠️ Experimental | Browser database & streaming adapted; third-party APIs usually need a same-origin proxy for CORS |

The current version is 0.4.1 (Director mode and the lorebook/character-card library delivered; iOS/macOS dual-platform adaptation complete). Versioning and release cadence will be settled as the open-source effort progresses.

## Roadmap

**Implemented**
- [x] Chat mode (multi-protocol BYOK, branches, compaction)
- [x] Story mode (experiential + factual memory, hybrid retrieval, failure recovery)
- [x] Director mode (project rules / watch mode / event log)
- [x] Lorebook & character-card import and application (SillyTavern-compatible)
- [x] iOS / macOS dual-platform adaptation (file drag & drop, close-window guard, authorization memory)
- [x] English UI (zh-CN / en-US, instant switching)

**In progress**
- [ ] Rolling fixes & polish from beta feedback
- [ ] Release cadence & repository governance (tag-based releases starting at v0.4.1)

**Future directions** (planned, not delivered)
- [ ] Journey archival / world chronicle export (multi-session archival & sharing; single-session manuscript export already implemented)
- [ ] First-class World object: one world, many journeys and timelines
- [ ] CHARX card format and broader ecosystem compatibility
- [ ] Official Web release

## Development, contribution & architecture

Feature-first Clean Architecture (`Presentation -> Domain <- Data`, shared infrastructure in `Core`):

```
Presentation -> Domain <- Data
                  ↑
                Core
```

```text
lib/
├── core/               # Infrastructure (networking, storage, config, theme)
├── features/
│   ├── chat/           # Chat mode + shell routing
│   ├── intermediate/   # Story mode (six-phase pipeline)
│   ├── advanced/       # Director mode (agent kernel, HITL, event log)
│   ├── story_runtime/  # Shared story/director runtime
│   ├── resource_library/ # Lorebook / character-card library
│   ├── memory/         # Memory subsystem
│   ├── settings/ templates/ diagnostics/ help/ onboarding/
└── i18n/               # Translations (zh-CN only currently)
```

Tech stack: Flutter / Riverpod / drift (SQLite) / dio + custom SSE / slang / Material 3.

- Contributing: [CONTRIBUTING.md](CONTRIBUTING.md)
- Documentation map & source-of-truth rules: [doc/README.md](doc/README.md)
- Project positioning: [doc/product/00_项目定位.md](doc/product/00_项目定位.md) (Chinese)

## Acknowledgements

- **[ChatBox](https://github.com/chatbox-org/chatbox)** — product & implementation reference for Chat mode
- **[Inter](https://github.com/rsms/inter)** — UI typeface, bundled under [SIL OFL 1.1](assets/fonts/Inter/OFL.txt)

## License

This project is open-sourced under [GPL-3.0](LICENSE).
