# Public-surface residual trace guard.
#
# Machine-checkable leak families only; fails CI when any tracked file leaks:
#   identity   - maintainer real-name/email fragments
#   gitee      - references to the private gitee mirror
#   network    - tailnet / private-network addresses
#   docpath    - internal process-document paths (doc/planning, doc/reports, ...)
#   toolpath   - internal tooling paths (.trae, .zcode, .impeccable, ...)
#
# Scope notes:
#   - doc/ prose is human-reviewed per doc/README.md, so the two path
#     families do not apply there; the identity/gitee/network families apply
#     to every tracked file without exception.
#   - doc/misc is left out of the docpath family on purpose: local-only test
#     fixtures reference doc/misc/... sample paths and skip when the samples
#     are absent; the directory name carries no workflow information. Every
#     other process directory is hard-blocked.
#   - .gitignore is exempt from the path families: it must keep listing the
#     local-only directories it keeps out of the repo.
#   - This script skips itself (its regex source would self-match).
#
# Exit codes: 0 = clean, 1 = leaks found (each printed as file:line [family]).
import re
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]

FAMILIES = (
    ("identity", re.compile(r"shiheming|da9906260|\bda990\b")),
    ("gitee", re.compile(r"gitee\.com", re.IGNORECASE)),
    ("network", re.compile(
        r"tailscale|ts\.net|\b100\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"
        r"|\b192\.168\.\d{1,3}\.\d{1,3}\.\d{1,3}\b"
        r"|\b10\.\d{1,3}\.\d{1,3}\.\d{1,3}\b|funnel", re.IGNORECASE)),
    ("docpath", re.compile(
        r"doc/(?:planning|reports|exploration|dev|meeting"
        r"|config-audit|ui-audit)")),
    ("toolpath", re.compile(
        r"\.trae|\.zcode|\.impeccable|decode_logs|longtask|exec-log"
        r"|/validation/|third_party")),
)

PATH_FAMILY_NAMES = frozenset({"docpath", "toolpath"})
SELF = Path(__file__).resolve()


def path_families_apply(rel: str) -> bool:
    if rel == ".gitignore":
        return False
    return not rel.startswith("doc/")


def is_binary(path: Path) -> bool:
    try:
        with open(path, "rb") as fh:
            return b"\x00" in fh.read(8192)
    except OSError:
        return True


def tracked_files() -> list[str]:
    out = subprocess.run(
        ["git", "-C", str(REPO_ROOT), "-c", "core.quotepath=false",
         "ls-files"],
        capture_output=True, text=True, encoding="utf-8", check=True,
    ).stdout
    return out.splitlines()


def main() -> int:
    hits = 0
    for rel in tracked_files():
        path = REPO_ROOT / rel
        if not path.is_file() or path.resolve() == SELF or is_binary(path):
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        active = [
            (name, pattern) for name, pattern in FAMILIES
            if name not in PATH_FAMILY_NAMES or path_families_apply(rel)
        ]
        for lineno, line in enumerate(text.splitlines(), 1):
            tags = [name for name, pattern in active if pattern.search(line)]
            if tags:
                hits += 1
                print(f"{rel}:{lineno} [{'/'.join(tags)}] {line.strip()[:160]}")
    print(f"--- residual trace check: {hits} hit(s)")
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main())
