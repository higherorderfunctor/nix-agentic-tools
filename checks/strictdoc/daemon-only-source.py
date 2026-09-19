#!/usr/bin/env python3
# cspell:ignore asname
"""Guard REQ-DAEMON-IS-THE-ONLY-SOURCE against new disk readers.

The scan covers Python programs under ``dev/scripts`` and ``docs/sdoc``. It
rejects imports of ``parse_sgra``, literal paths to ``grammar.sgra``, and the
combination of ``os.walk`` with an ``.sdoc`` suffix. Sandboxed checks and test
fixtures are allowed readers. The daemon implementation is allowed to load its
own graph. ``dev/scripts/sdoc_semantics`` is allowlisted as the requirement's
recorded violation; it must disappear when the operator-defined semantics
representation exists.

One narrow exception remains, named by FINDING rather than by file:
``view-check.py`` walks the worktree for ``.sdoc`` files. The view pipeline's
input is a hand-run ``strictdoc export``, and only an export that goes through
``sdoc_model`` carries ``_DOCUMENT_PATH``, so the walk cannot be replaced until
that pipeline reads the daemon's export. Scoping the exception to the one
finding keeps a grammar read added to the same file refused.
"""

from __future__ import annotations

import ast
import sys
from pathlib import Path


SCAN_ROOTS = (Path("dev/scripts"), Path("docs/sdoc"))

ALLOWED_PATHS = {
    # The daemon and its graph/grammar implementation.
    Path("dev/scripts/scribe_daemon.py"),
    Path("dev/scripts/scribe_grammar.py"),
    Path("dev/scripts/scribe_workspace.py"),
    Path("dev/scripts/sdoc_model.py"),
    # This helper runs only inside the sandboxed grammar-groups check.
    Path("dev/scripts/grammar-groups-check.py"),
}
ALLOWED_PREFIXES = (
    Path("checks"),
    # RECORDED VIOLATION: REQ-DAEMON-IS-THE-ONLY-SOURCE reserves this until
    # the operator defines a daemon representation for the semantics model.
    Path("dev/scripts/sdoc_semantics"),
)
# Keyed by path, valued by the EXACT findings tolerated there. Adding a path
# here is deliberately more work than adding one to ALLOWED_PATHS: an entry
# has to name the finding it forgives.
NARROW_EXCEPTIONS = {
    Path("docs/sdoc/view/view-check.py"): {
        "walks the filesystem for .sdoc files",
    },
}


def is_allowed(path: Path) -> bool:
    if path.name.startswith("test_"):
        return True
    if path in ALLOWED_PATHS:
        return True
    return any(path.is_relative_to(prefix) for prefix in ALLOWED_PREFIXES)


def imported_walk_names(tree: ast.AST) -> tuple[set[str], set[str]]:
    """Return aliases for the os module and for directly imported os.walk."""
    os_names = {"os"}
    walk_names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name == "os":
                    os_names.add(alias.asname or alias.name)
        elif isinstance(node, ast.ImportFrom) and node.module == "os":
            for alias in node.names:
                if alias.name == "walk":
                    walk_names.add(alias.asname or alias.name)
    return os_names, walk_names


def findings(path: Path, source: str) -> list[str]:
    try:
        tree = ast.parse(source, filename=str(path))
    except SyntaxError as error:
        return [f"cannot parse Python: {error.msg} at line {error.lineno}"]

    result: list[str] = []
    os_names, walk_names = imported_walk_names(tree)
    has_sdoc_suffix = False
    uses_os_walk = False

    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom):
            if any(alias.name == "parse_sgra" for alias in node.names):
                result.append(f"line {node.lineno}: imports parse_sgra")
        elif isinstance(node, ast.Constant) and isinstance(node.value, str):
            literal = node.value.replace("\\", "/")
            if literal == "grammar.sgra" or literal.endswith("/grammar.sgra"):
                result.append(f"line {node.lineno}: names a grammar.sgra path literal")
            if literal in {".sdoc", "*.sdoc"}:
                has_sdoc_suffix = True
        elif isinstance(node, ast.Call):
            function = node.func
            if isinstance(function, ast.Name) and function.id in walk_names:
                uses_os_walk = True
            elif (
                isinstance(function, ast.Attribute)
                and function.attr == "walk"
                and isinstance(function.value, ast.Name)
                and function.value.id in os_names
            ):
                uses_os_walk = True

    if uses_os_walk and has_sdoc_suffix:
        result.append("walks the filesystem for .sdoc files")
    return result


def scan(root: Path) -> list[str]:
    failures: list[str] = []
    for scan_root in SCAN_ROOTS:
        directory = root / scan_root
        if not directory.is_dir():
            failures.append(f"{scan_root}: scan root does not exist")
            continue
        for absolute in sorted(directory.rglob("*.py")):
            relative = absolute.relative_to(root)
            if is_allowed(relative):
                continue
            for finding in findings(
                relative, absolute.read_text(encoding="utf8", errors="strict")
            ):
                if finding in NARROW_EXCEPTIONS.get(relative, set()):
                    continue
                failures.append(f"{relative}: {finding}")
    return failures


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {Path(argv[0]).name} REPOSITORY", file=sys.stderr)
        return 2
    root = Path(argv[1]).resolve()
    failures = scan(root)
    for failure in failures:
        print(f"FAIL {failure}", file=sys.stderr)
    if failures:
        print(f"daemon-only-source: {len(failures)} finding(s)", file=sys.stderr)
        return 1
    print("daemon-only-source: no unauthorized disk readers")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
