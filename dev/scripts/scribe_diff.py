#!/usr/bin/env python3
# cspell:ignore keepends tofile
"""Render the path-by-path diff shared by both sdoc writer CLIs."""

from __future__ import annotations

import difflib
from collections.abc import Mapping
from pathlib import Path


def unified_pending_diff(pending: Mapping[Path, str | None], root: Path) -> str:
    """Diff rendered pending content against each path's current bytes."""
    chunks: list[bytes] = []
    for path, content in pending.items():
        name = str(path.relative_to(root))
        before = path.read_bytes() if path.exists() else b""
        after = content.encode("utf8") if content is not None else b""
        fromfile = f"a/{name}".encode()
        tofile = (f"b/{name}" if content is not None else "/dev/null").encode()
        chunks.extend(
            difflib.diff_bytes(
                difflib.unified_diff,
                before.splitlines(keepends=True),
                after.splitlines(keepends=True),
                fromfile=fromfile,
                tofile=tofile,
            )
        )
    return b"".join(chunks).decode("utf8") or "nothing would change\n"
