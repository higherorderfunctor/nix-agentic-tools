#!/usr/bin/env python3
"""Reject launcher commands that resolve Python or Node from ambient PATH."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

INTERPRETER = r"(?:python(?:[0-9]+(?:\.[0-9]+)*)?|node)"
ENV_ARGS = r"(?:(?:-u\s+\S+|--unset(?:=\S+)?|[A-Za-z_]\w*=\S+)\s+)*"
COMMAND = rf"(?:exec\s+)?(?:env\s+{ENV_ARGS})?(?P<name>{INTERPRETER})(?!\s*=)(?:\s|$)"
BARE_COMMAND = re.compile(rf"(?:^|(?:&&|\|\||[;|])\s*)\s*{COMMAND}")
EXEC_ASSIGNMENT = re.compile(rf"\bexec\s*=\s*(?:['\"]|'')?\s*{COMMAND}")


def is_shell_launcher(path: Path) -> bool:
    try:
        first = path.open(encoding="utf8").readline()
    except (OSError, UnicodeDecodeError):
        return False
    return first.startswith("#!") and any(shell in first for shell in ("bash", "sh"))


def discovered_paths(root: Path) -> list[Path]:
    paths = {root / "devenv.nix"}
    paths.update((root / "dev" / "tasks").rglob("*.nix"))
    paths.update((root / "packages").glob("*/modules/devenv/**/*.nix"))
    for directory in (root / "dev", root / "docs"):
        paths.update(
            path
            for path in directory.rglob("*")
            if path.is_file() and path.stat().st_mode & 0o111 and is_shell_launcher(path)
        )
    return sorted(path for path in paths if path.is_file())


def findings(root: Path, paths: list[Path]) -> list[str]:
    result = []
    for path in paths:
        relative = path.relative_to(root) if path.is_relative_to(root) else path
        shell_launcher = is_shell_launcher(path)
        for line_number, line in enumerate(path.read_text(encoding="utf8").splitlines(), 1):
            stripped = line.lstrip()
            if stripped.startswith(("#", "//")):
                continue
            match = EXEC_ASSIGNMENT.search(line)
            if match is None and shell_launcher:
                match = BARE_COMMAND.search(line)
            elif match is None and path.suffix == ".nix":
                match = BARE_COMMAND.search(line)
            if match is not None:
                result.append(
                    f"{relative}:{line_number}: bare interpreter {match.group('name')}: {stripped}"
                )
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("paths", nargs="*", type=Path)
    args = parser.parse_args(argv)
    root = args.root.resolve()
    paths = [path.resolve() for path in args.paths] or discovered_paths(root)
    if not paths:
        print("interpreter-launchers: no inputs", file=sys.stderr)
        return 2
    problems = findings(root, paths)
    if problems:
        print("\n".join(problems), file=sys.stderr)
        return 1
    print(f"interpreter-launchers: {len(paths)} files, 0 findings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
