# Repository Instructions for Coding Agents

This file applies to the entire repository. Read it before making changes.
`CLAUDE.md`, `CONTRIBUTING.md`, and `doc/README.md` remain authoritative;
this file is the agent-oriented execution checklist that consolidates their
most important rules.

## Source of Truth

1. Current executable code, database schema, generated code, and tests that
   match the current API.
2. Newer maintained design decisions.
3. Older design documents and implementation plans.

Code wins when sources disagree. Check `doc/README.md` for document status and
update maintained design docs, the glossary, and the in-app Wiki when behavior
or product terminology changes.

## Architecture and Product Invariants

- Follow feature-first Clean Architecture: `Presentation -> Domain <- Data`,
  with shared infrastructure in `Core`.
- Domain code must not import Flutter or Data implementations.
- Repositories expose persistence operations; business policy belongs in
  services and controllers.
- Shared defaults come from `assets/configs/default_config.json`.
- Story generation and persistence are transactional. Cancelled or incomplete
  rounds must not leave partial final state.
- Implemented product modes are `chat`, `intermediate` (story), and `advanced`
  (director mode, product name "导演模式"). `advanced` is implemented: its
  kernel lives in `lib/features/advanced/` (AgentRunner/tools/prompts/event
  log, `AdvancedChatController` + `DirectorRoundRunner`), and it shares the
  story runtime (persistence, compaction, retry, phase models) through
  `lib/features/story_runtime/`. The reusable agent-loop contract lives in
  `lib/core/agent/`. Do not recreate the abandoned HUD design, and do not
  reintroduce mid-round steering: to correct a running story, edit the message
  and regenerate.
- Preserve user data in database upgrades and repair paths.

## Editing Rules

- Preserve unrelated changes in a dirty worktree. Inspect `git status` and the
  relevant diffs before editing and before staging.
- Never edit generated `*.g.dart`, `*.freezed.dart`, or generated i18n files by
  hand.
- After drift table, Riverpod provider, or serializable-model changes, run:
  `dart run build_runner build --delete-conflicting-outputs`.
- After changing `lib/i18n/*.i18n.yaml`, run `dart run slang`.
- Keep user-visible text in slang resources; do not hard-code it in widgets.
  Two CI regression guards enforce this: every `showSnackBar(` must set
  `SnackBarBehavior.floating` within 6 lines, and Chinese string literals in
  `presentation/**`, `core/theme/**`, and `core/widgets/**` must go through
  slang (model-facing envelope/prompt strings and audit reasons excepted).
  The whitelists under `tool/ci_guards/` count `path:count` entries and only
  shrink: never raise a count, never add a violating file, and delete entries
  that reach zero.
- When a change alters user-visible behavior, update the affected maintained
  design docs, the glossary, the in-app Wiki, and `CHANGELOG.md` in the same
  change.
- Keep code comments and test names about behavior, not process: no ticket or
  decision IDs, review-round labels, or date-stamped decision notes. Process
  context belongs in project documentation and issue discussions, not in code.
- Follow `very_good_analysis`, null-safe control flow, `snake_case` filenames,
  `PascalCase` types, and `camelCase` members.

## Required Validation

Before committing an implementation change:

1. Format touched Dart files (or run `dart format lib/ test/`).
2. Run `flutter analyze`; add no errors/warnings and resolve lint introduced
   by the current change.
3. Run relevant focused tests, then `flutter test` for the full suite.
4. Run code generation when required by the editing rules above.
5. Run the CI guards locally when you touched snackbar or literal-sensitive
   code: `python tool/ci_guards/check_snackbar_floating.py` and
   `python tool/ci_guards/check_chinese_literals.py`.
6. Inspect `git diff --check` and the final staged diff.
7. Record any environment-only validation blocker separately; do not describe
   a dependency download failure as a source compilation failure.

## Git Delivery

- An implementation task is not complete until its in-scope changes are
  committed, unless the user explicitly asks not to commit or asks only for a
  review/diagnosis.
- Stage only the current task's files and hunks. Never include pre-existing or
  unrelated user changes merely because they share the worktree or a file.
- Use Conventional Commits, for example: `feat: ...`, `fix: ...`,
  `refactor: ...`, `test: ...`, `docs: ...`, or `chore: ...`.
- Do not rewrite, discard, reset, or amend user work unless explicitly asked.
- Report the commit hash, tests run, and any remaining validation limitation in
  the final handoff.
