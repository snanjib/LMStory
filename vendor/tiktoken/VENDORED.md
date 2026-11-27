# Vendored fork: tiktoken 1.0.3

Upstream: https://github.com/mishamosher/flutter_tiktoken (MIT License,
unchanged `LICENSE` in this directory). Published on pub.dev as `tiktoken`
1.0.3 — the latest release, unchanged for three years.

## Why this fork exists

Upstream generates `lib/src/ranks/cl100k_base.tiktoken.dart` with a
~100k-entry `final` map literal. Under the Dart VM shipped with Flutter
3.47.7, that giant literal is lazily initialized with **probabilistic
corruption**:

- intermittent `TypeError` (`_Type` / `TypeArguments` "is not a subtype of
  String") raised from `Map._fromLiteral` during the first `getEncoding`
  call of a process/isolate — observed on GitHub Actions ubuntu runners
  (2026-11-27/28) and rarely on macOS;
- in the worst case the flutter_tester shell segfaults during teardown.

AOT production builds evaluate the literal deterministically at build time
and are unaffected; the instability is a JIT/flutter_tester phenomenon.

## The change

Exactly one file differs from upstream 1.0.3:
`lib/src/ranks/cl100k_base.tiktoken.dart`. The same rank data (100104
entries, identical ordering and values) is embedded as a plain-text
constant and parsed at runtime into the map, keeping the huge map literal
out of the evaluation path entirely. The public API (`getEncoding`, BPE
behaviour, token ids) is byte-for-byte equivalent to upstream; regression
coverage lives in the host app's test suite
(`test/core/utils/token_counter_data_test.dart`).

Upstream's `test/`, `example/` and `tool/` trees are pruned from this
copy: they target `package:test` (absent from the host app) and rank
downloading is not used here.

If another encoding's rank file is ever needed, apply the same
data-string + runtime-parse transformation (see the cl100k file header).
