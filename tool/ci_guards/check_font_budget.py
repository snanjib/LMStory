#!/usr/bin/env python3
"""字体资产体积门禁（阅读/mono 字体打包策略）。

规则：assets/fonts/ 下的字体文件逐个计入白名单（路径:字节），白名单
只减不增——体积增长、新增文件未登记、白名单内文件消失都视为门禁失败；
实际体积更低则通过并提示收缩。OFL.txt 等非字体文件不计入。

背景：三族 OFL 子集（LMSerif/LMSerifSC/LMMono）是产物级资产，
体积是 APK 增量的主项；Inter 打包存量一并纳入锁面。

用法：python tool/ci_guards/check_font_budget.py（CI 步骤）。
退出码 0=通过；1=违规。
"""

from __future__ import annotations

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
FONTS_ROOT = REPO_ROOT / "assets" / "fonts"
WHITELIST_FILE = Path(__file__).resolve().parent / "font_budget_whitelist.txt"


def load_whitelist() -> dict[str, int]:
    entries: dict[str, int] = {}
    for line in WHITELIST_FILE.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        rel, _, size = line.rpartition(":")
        if not rel or not size.isdigit():
            print(f"whitelist 格式错误: {line!r}", file=sys.stderr)
            sys.exit(1)
        entries[rel] = int(size)
    return entries


def main() -> int:
    if not FONTS_ROOT.is_dir():
        print("assets/fonts/ 不存在", file=sys.stderr)
        return 1
    whitelist = load_whitelist()
    actual: dict[str, int] = {}
    for path in sorted(FONTS_ROOT.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in (".ttf", ".otf", ".woff", ".woff2"):
            continue
        rel = path.relative_to(REPO_ROOT).as_posix()
        actual[rel] = path.stat().st_size

    failures: list[str] = []
    shrinks: list[str] = []
    for rel, size in sorted(actual.items()):
        locked = whitelist.get(rel)
        if locked is None:
            failures.append(f"未登记的新字体文件: {rel} ({size} bytes)")
        elif size > locked:
            failures.append(f"体积增长: {rel} {locked} -> {size} bytes")
        elif size < locked:
            shrinks.append(f"{rel} {locked} -> {size} bytes（请下调白名单）")

    for rel in sorted(whitelist):
        if rel not in actual:
            failures.append(f"白名单内文件已不存在: {rel}（请删除该行）")

    for line in failures:
        print(f"[font-budget] FAIL {line}")
    for line in shrinks:
        print(f"[font-budget] shrink {line}")
    total = sum(actual.values())
    print(
        f"font budget check: {len(actual)} files, {total} bytes "
        f"({total / 1024 / 1024:.2f} MiB) — "
        + ("passed" if not failures else "FAILED")
    )
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
