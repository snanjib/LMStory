#!/usr/bin/env python3
"""SnackBar 浮层门禁（B2，第四轮审查防再生）。

规则：lib/ 内任何 `showSnackBar(` 调用，其后 6 行窗口内必须出现
`SnackBarBehavior.floating`——非浮层 SnackBar 在多窗口/键盘场景会
遮挡输入区且无法dismiss，历史上已多次回归（第四轮审查多分册）。

存量白名单：`tool/ci_guards/snackbar_whitelist.txt`（文件级，只减不增；
修复一处即可从白名单删除对应文件，新增违规文件加入白名单视为门禁失败）。

用法：python tool/ci_guards/check_snackbar_floating.py（CI 步骤）。
退出码 0=通过；1=有新违规（或白名单里出现已修复/不存在的文件）。
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCAN_ROOT = REPO_ROOT / "lib"
WHITELIST_FILE = Path(__file__).resolve().parent / "snackbar_whitelist.txt"
WINDOW_LINES = 6


def load_whitelist() -> set[str]:
    if not WHITELIST_FILE.exists():
        return set()
    entries = set()
    for line in WHITELIST_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            entries.add(line)
    return entries


def find_violations() -> dict[str, list[int]]:
    """按文件收集违规行号（showSnackBar 后 6 行内无 floating）。"""
    violations: dict[str, list[int]] = {}
    for path in sorted(SCAN_ROOT.rglob("*.dart")):
        rel = path.relative_to(REPO_ROOT).as_posix()
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeDecodeError) as e:  # pragma: no cover
            print(f"read fail: {rel}: {e}", file=sys.stderr)
            continue
        for idx, line in enumerate(lines):
            if "showSnackBar(" not in line:
                continue
            window = " ".join(lines[idx : idx + WINDOW_LINES])
            if "SnackBarBehavior.floating" not in window:
                violations.setdefault(rel, []).append(idx + 1)
    return violations


def main() -> int:
    whitelist = load_whitelist()
    violations = find_violations()

    new_files = sorted(set(violations) - whitelist)
    stale_entries = sorted(whitelist - set(violations))

    failed = False
    for rel in new_files:
        for ln in violations[rel]:
            print(f"NEW VIOLATION: {rel}:{ln} showSnackBar 缺 SnackBarBehavior.floating")
        failed = True
    for rel in stale_entries:
        print(
            f"WHITELIST STALE: {rel} 已无违规，请从 {WHITELIST_FILE.name} 删除（只减不增）"
        )
        failed = True

    if not failed:
        print(
            f"SnackBar floating check passed "
            f"({sum(len(v) for v in violations.values())} whitelisted occurrences in "
            f"{len(violations)} files)"
        )
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
