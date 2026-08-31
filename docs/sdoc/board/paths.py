#!/usr/bin/env python3
"""Resolve board workspace, state, and runtime paths without importing StrictDoc."""

from __future__ import annotations

import hashlib
import os
import tempfile
from pathlib import Path


def find_project_root(start: Path) -> Path:
    """Walk upward to the StrictDoc project marker."""
    current = start.expanduser().resolve()
    if current.is_file():
        current = current.parent
    for candidate in (current, *current.parents):
        if (candidate / "strictdoc_config.py").is_file():
            return candidate
    raise FileNotFoundError(f"no strictdoc_config.py above {start}")


def workspace_key(project_root: Path) -> str:
    """Return a short stable identity for one absolute workspace root."""
    root = find_project_root(project_root)
    return hashlib.sha256(str(root).encode("utf-8")).hexdigest()[:20]


def default_state_dir(project_root: Path) -> Path:
    """Put restart-persistent board state outside the checkout."""
    cache_home = os.environ.get("XDG_CACHE_HOME")
    base = Path(cache_home).expanduser() if cache_home else Path.home() / ".cache"
    return base / "sdoc-board" / workspace_key(project_root)


def default_runtime_dir() -> Path:
    """Return a short, user-private directory suitable for Unix sockets."""
    runtime_home = os.environ.get("XDG_RUNTIME_DIR")
    if runtime_home:
        return Path(runtime_home) / "sdoc-board"
    return Path(tempfile.gettempdir()) / f"sdoc-board-{os.getuid()}"


def default_socket_path(project_root: Path) -> Path:
    return default_runtime_dir() / f"{workspace_key(project_root)}.sock"
