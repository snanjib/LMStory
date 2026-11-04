#!/usr/bin/env python3
"""中文字面量门禁（B2，第四轮审查防再生 WK 系；XC7-7 扩面 + 白名单计数化）。

规则：`lib/features/**/presentation/**`、`lib/core/theme/**` 与
`lib/core/widgets/**` 内的 Dart 字符串字面量不得包含中文字符
（[\\u4e00-\\u9fa5]）——用户可见文案必须走 slang 资源（AGENTS.md 编辑
规则）。注释不参与检查。

合法例外（白名单显式枚举，`文件路径:登记条数` 计数锁，只减不增）：
- AgentTool 面向模型的信封/描述（模型输入，非 UI 文案）
- 提示词常量 / 审计 reason / 日志 detail（非用户可见）
- 白名单文件：`tool/ci_guards/chinese_literal_whitelist.txt`

计数锁（把「白名单只缩不涨」机械化）：
- 白名单内文件实际违规数 > 登记数 → 失败（禁止上调登记数，须修新增）。
- 实际违规数 < 登记数 → 通过，但提示收紧登记数；降为 0 则该行整体
  失效，必须从白名单删除（同旧「文件级失效」规则）。
- 不在白名单的文件出现任何违规 → 失败（新增文件不得加入白名单）。

仅用标准库（re/sys/pathlib），零第三方依赖。

用法：python tool/ci_guards/check_chinese_literals.py
退出码 0=通过；1=新违规（或白名单失效/格式错误/计数上调）。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
WHITELIST_FILE = Path(__file__).resolve().parent / "chinese_literal_whitelist.txt"
SCAN_GLOBS = (
    "lib/features/*/presentation/**/*.dart",
    "lib/core/theme/**/*.dart",
    "lib/core/widgets/**/*.dart",
)

CJK = re.compile(r"[\u4e00-\u9fa5]")

# 去注释：行注释 + 块注释（状态机），字符串内容保留。
def strip_comments(source: str) -> str:
    out = []
    i = 0
    n = len(source)
    state = "code"  # code | line_comment | block_comment | squote | dquote | raw_s | raw_d
    while i < n:
        c = source[i]
        nxt = source[i + 1] if i + 1 < n else ""
        if state == "code":
            if c == "/" and nxt == "/":
                state = "line_comment"
                i += 2
                continue
            if c == "/" and nxt == "*":
                state = "block_comment"
                i += 2
                continue
            if c == "'":
                state = "raw_s" if (i > 0 and source[i - 1] == "r") else "squote"
                out.append(c)
                i += 1
                continue
            if c == '"':
                state = "raw_d" if (i > 0 and source[i - 1] == "r") else "dquote"
                out.append(c)
                i += 1
                continue
            out.append(c)
            i += 1
        elif state == "line_comment":
            if c == "\n":
                state = "code"
                out.append(c)
            i += 1
        elif state == "block_comment":
            if c == "*" and nxt == "/":
                state = "code"
                i += 2
            else:
                if c == "\n":
                    out.append(c)
                i += 1
        else:  # inside string
            quote = "'" if state in ("squote", "raw_s") else '"'
            raw = state in ("raw_s", "raw_d")
            if c == "\\" and not raw:
                out.append(c)
                if i + 1 < n:
                    out.append(source[i + 1])
                i += 2
                continue
            if c == quote:
                state = "code"
            out.append(c)
            i += 1
    return "".join(out)


def find_string_literals(code: str):
    """yield (col, text) — 单/双引号字符串（含 raw），保守正则。"""
    pattern = re.compile(r"r?(?:'(?:[^'\\\n]|\\.)*'|\"(?:[^\"\\\n]|\\.)*\")")
    for m in pattern.finditer(code):
        yield m.start(), m.group(0)


def find_violations() -> dict[str, list[tuple[int, str]]]:
    violations: dict[str, list[tuple[int, str]]] = {}
    files: set[Path] = set()
    for pattern in SCAN_GLOBS:
        files.update(REPO_ROOT.glob(pattern))
    for path in sorted(files):
        rel = path.relative_to(REPO_ROOT).as_posix()
        try:
            source = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as e:  # pragma: no cover
            print(f"read fail: {rel}: {e}", file=sys.stderr)
            continue
        stripped = strip_comments(source)
        for offset, text in find_string_literals(stripped):
            if CJK.search(text):
                line = stripped.count("\n", 0, offset) + 1
                violations.setdefault(rel, []).append((line, text))
    return violations


def load_whitelist() -> tuple[dict[str, int], list[str]]:
    """返回（路径 → 登记违规数, 格式错误行）。每行格式：`文件路径:条数`。"""
    if not WHITELIST_FILE.exists():
        return {}, []
    entries: dict[str, int] = {}
    errors: list[str] = []
    for raw in WHITELIST_FILE.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        path, sep, count = line.rpartition(":")
        if not sep or not path or not count.isdigit() or int(count) <= 0:
            errors.append(line)
            continue
        if path in entries:
            errors.append(line)
            continue
        entries[path] = int(count)
    return entries, errors


def main() -> int:
    whitelist, format_errors = load_whitelist()
    violations = find_violations()

    failed = False
    for line in format_errors:
        print(
            f"WHITELIST FORMAT: 「{line}」应为『文件路径:正整数条数』；"
            f"已清零的文件请直接删除该行"
        )
        failed = True

    for rel in sorted(set(violations) - set(whitelist)):
        for ln, text in violations[rel]:
            preview = text if len(text) <= 60 else text[:57] + "..."
            print(f"NEW VIOLATION: {rel}:{ln} 中文字面量 {preview}")
        failed = True

    for rel in sorted(whitelist):
        actual = len(violations.get(rel, []))
        registered = whitelist[rel]
        if actual > registered:
            print(
                f"COUNT EXCEEDED: {rel} 实际 {actual} 处 > 登记 {registered} 处；"
                f"白名单只减不增，禁止上调登记数，请修复新增违规："
            )
            for ln, text in violations[rel]:
                preview = text if len(text) <= 60 else text[:57] + "..."
                print(f"  {rel}:{ln} 中文字面量 {preview}")
            failed = True
        elif actual == 0:
            print(
                f"WHITELIST STALE: {rel} 已无中文字面量，请从 "
                f"{WHITELIST_FILE.name} 删除该行（只减不增）"
            )
            failed = True
        elif actual < registered:
            print(
                f"SHRINK HINT: {rel} 实际 {actual} 处 < 登记 {registered} 处，"
                f"请把登记数收紧为 {actual}（只减不增；提示不阻断 CI）"
            )

    if not failed:
        total = sum(len(v) for v in violations.values())
        print(
            f"Chinese literal check passed "
            f"({total} whitelisted literals in {len(violations)} files)"
        )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
