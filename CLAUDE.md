# CLAUDE.md

This file is the source of truth for project knowledge and current boundaries:
what the project is, how it is organized, and which designs are abandoned. The
source of truth for coding-agent behavior rules (task scope, editing
discipline, validation checklist, Git delivery) is `AGENTS.md` — read and
follow it before making changes.

## Project Overview

LMStory is a Flutter application for general AI chat and memory-backed interactive storytelling. The three implemented product modes are:

| Code identifier | User-facing name | Status |
|---|---|---|
| `chat` | 对话模式 / Chat mode | Implemented |
| `intermediate` | 故事模式 / Story mode | Implemented |
| `advanced` | 导演模式 / Director mode | Implemented (toggle in Settings, on by default) |

Director mode (`advanced`) is the v0.3 Agent Loop: an AI backstage executor that runs the world under user-authored "project rules" and produces the story text as the single outcome. Its kernel lives in `lib/features/advanced/` (AgentRunner, tools, skills, durable event log, HITL ask/approval, watch mode, spawn subagent, maxSteps soft landing, story anchor/recap), and it shares the story runtime (persistence, compaction, retry, phase models) with Story mode through `lib/features/story_runtime/`. The reusable agent-loop contract (runner, tool pipeline, gateway) lives in `lib/core/agent/`. Design docs: `doc/design/v0.3.0/`. The former standalone HUD, `factual_memories` single-table, `state_snapshots`, and HUD-specific `update_world` pipeline are abandoned designs, not future requirements. Mid-round steering was removed: to correct a running story, edit the message and regenerate.

The application ships two locales, `zh-CN` and `en-US` (the English UI is
fully delivered, with key parity against zh and a zh-en parity guard in CI).
Switch language in Settings → 语言与输入; the choice persists. "Follow
system" is not offered yet (selector placeholder).

## Source of Truth and Document Status

When sources disagree, use this order:

1. Current executable code, database schema, generated code, and tests that match the current API.
2. Newer maintained design decisions.
3. Older design documents and implementation plans.

Code wins over documents. Update affected design docs, the glossary, and the in-app Wiki in the same change. Older design documents describe historical snapshots; do not reinterpret them as current behavior.

The document map and status rules live in `doc/README.md`. Use the following references with their stated status:

| Area | Primary references |
|---|---|
| Current product boundary | `doc/design/01_项目概要设计.md` |
| System/Web evolution | `doc/design/02_系统设计.md` (historical mixed draft; verify against code) |
| Interfaces | `doc/design/05_*` (historical snapshots; source signatures from code) |
| Shared UI | `doc/design/06_UI设计规范.md` |
| Chat mode UI | `doc/design/06A_Simple模式视觉规范.md` |
| Story mode UI | `doc/design/06B_中级模式视觉规范.md` |
| i18n infrastructure and rollout status | `doc/design/07_国际化设计.md` |
| Story mode architecture and flow | `doc/design/08_*`, `doc/design/09_*` (use their 2026-08-11 calibration notices) |
| Memory and context | `doc/design/10_*`, `doc/design/11_*`, `doc/design/13_*` |
| Provider protocols | `doc/design/12_供应商模板与多协议适配设计.md` |
| Settings interaction | `doc/design/14_设置交互优化设计.md` |
| Director mode (Agent Loop) design | `doc/design/v0.3.0/` (调研规划、体验重构方案、设置体系、剧情节奏、正文交付契约、上下文用量指示、长会话退化治理、AI建卡工具、记忆库实体归并); historical direction drafts: `doc/design/03A_v0.3子系统设计.md`, `doc/design/04A_v0.3详细设计.md` |
| Worldbook / character cards | `doc/design/15_世界书与角色卡设计.md` (implemented in `lib/features/resource_library/` and `lib/features/resource_ai/`) |
| Appearance system v2 & component interface layer | `doc/design/v0.4.0/` (dual-axis appearance system, LmComponentKit interface layer, structure research snapshots) |
| Project positioning (external messaging) | `doc/product/00_项目定位.md` |

Director mode has no standalone visual specification: it reuses the 06B story-mode visual spec plus the global three-axis appearance system (structure × palette × day/night; the early "nightVoyage" theme was absorbed into the global night base — there is no standalone nightVoyage theme anymore) and the theater-language UI spec in `doc/design/v0.3.0/导演模式体验重构调研与方案.md` §4. Do not recreate the abandoned HUD design as `06C`.

## Reference Project

- **ChatBox** (<https://github.com/chatbox-org/chatbox>): product and implementation reference for standard Chat mode behavior such as sessions, message operations, branches, compaction, and common chat UI patterns.
- **DeepSeek Harness** (<https://github.com/deepseek-ai/deepseek-harness>): agent harness reference for the v0.3 Agent Loop — "everything is a plugin" (Cordis), append-only session log + surface projection, tool-pipeline waterfalls/monotonic guards, skill/subagent/compaction/spill. Deep-dive and portability analysis live in `doc/design/v0.3.0/Agent_Loop前期调研与规划.md` §3.3 and §7.
- **opencode** (<https://github.com/sst/opencode>): the primary reference for the v0.3 导演模式 (Director mode) frontend and agent-loop ergonomics — the three-layer loop (runLoop/process/llm), the Message/Part model with tool parts as a state machine, the unified tool-result envelope/truncation, and, most importantly for product work, its **client UI**: conversation-first layout where the agent's work is a collapsible timeline/drawer, not the primary content, with the narrative/result as the final output. Director mode must feel like Story mode with a swapped kernel; when rebuilding the Director UI, model it on opencode's frontend rather than inventing a dashboard.

## Commands

```bash
dart pub get
dart run build_runner build --delete-conflicting-outputs
dart run slang
flutter analyze
flutter test
dart format lib/ test/
flutter run
flutter build apk --release
flutter build web --release
```

After changing drift tables, Riverpod providers, or serializable models, rerun `build_runner`. After changing `lib/i18n/*.i18n.yaml`, run `dart run slang`; do not edit generated translation files manually. CI also runs two regression guards from `tool/ci_guards/` (SnackBar floating behavior, Chinese literal whitelist); run them locally when touching sensitive code.

## Architecture

The project uses feature-first Clean Architecture:

```text
Presentation -> Domain <- Data
                  ^
                 Core
```

- **Domain**: pure Dart entities, repository abstractions, and services/use cases.
- **Data**: drift/SQLite persistence and Dio/SSE/LLM adapters.
- **Presentation**: Flutter widgets and Riverpod controllers.
- **Core**: shared infrastructure, including the reusable agent loop in `core/agent`. Avoid adding feature-specific business policy; a small number of historical Core-to-feature/domain imports remain and should be reduced, not treated as the desired boundary.

Current feature directories: `chat` (chat mode + shell routing in `main_layout`), `intermediate` (story mode), `advanced` (director mode), `story_runtime` (shared story/director runtime), `resource_library` (worldbook/character cards), `resource_ai` (AI card/lorebook builder), `memory`, `onboarding`, `settings`, `templates`, `diagnostics`, and `help`. There is no `features/hud`.

Important invariants:

1. Domain does not import Flutter or Data implementations.
2. Repository interfaces expose business identifiers, not drift/Dio implementation types.
3. Business policy belongs in services/controllers, not data-access repositories.
4. Configuration defaults come from `assets/configs/default_config.json`; legacy JSON/DB keys may be retained only when code explicitly supports compatibility.
5. Story generation and its persistence are transactional: incomplete/cancelled rounds must not leave partial final state.
6. Stable prompt prefixes come first where possible to improve LLM cache reuse.

## Current Story and Memory Model

The Story mode pipeline is:

```text
compacting? -> extracting -> retrieving -> generating -> reviewing? -> summarizing -> persisting
```

`reviewing` is optional and disabled by default. User-facing terms are “生成/审查”; old “草稿/终稿” terms are historical only. Some persisted compatibility keys may still use old words only where the current schema or parser explicitly documents them.

Memory is organized by content, not by short/long-term tiers:

| Type | Current storage | Behavior |
|---|---|---|
| Experiential memory | `experiential_memories` + `memories_fts` | Append-oriented story events, FTS5 + vector retrieval |
| Factual memory | `factual_entities` + `factual_attributes` + `factual_memory_history` | Structured facts with update history |
| Working context | Rebuilt per request | Prompt messages sent to the model; not an independent memory table |

The v0.3 Agent Loop (Director mode) reuses this implemented memory foundation; it does not maintain a parallel store.

## Protocol and Platform Status

- Implemented LLM protocols: OpenAI-compatible Chat Completions, Anthropic Messages, and Gemini native.
- OpenAI Responses is reserved but not implemented; never expose it as a selectable working protocol.
- Built-in provider templates: OpenAI, DeepSeek, OpenRouter, Anthropic Claude, Google Gemini, NVIDIA NIM, and Agnes AI.
- Web uses drift WASM/IndexedDB and a Web streaming client. Third-party API calls generally require the same-origin proxy described in `doc/design/02_系统设计.md` because of CORS.

## Configuration and Database

Runtime configuration: `assets/configs/default_config.json`, loaded by `lib/core/config/config_loader.dart`.

The database `schemaVersion` is defined in
`lib/features/chat/data/database/app_database.dart` — this file is the single
source of truth for the current number; do not rely on numbers quoted
elsewhere. Upgrades and repairs use additive `repairSchema` behavior and must
preserve user data; do not reintroduce the obsolete “delete the dev database /
rebuild on every upgrade” strategy.

## Code Conventions

- Lint rules: `very_good_analysis`.
- Never edit generated `*.g.dart` / `*.freezed.dart` / generated i18n files manually.
- Files use `snake_case`; types use `PascalCase`; members use `camelCase`.
- Prefer null-safe control flow over non-null assertions.
- Keep user-visible text in slang resources. A translation key does not mean a second locale is implemented.
- Preserve unrelated user changes in a dirty worktree.
