#!/usr/bin/env python3
"""Own one resident StrictDoc project and publish immutable generations."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from snapshot import LoadedProject, find_project_root, load_project

WORKSPACE_SCHEMA = "sdoc-board-workspace/1"
Loader = Callable[[Path, Path], LoadedProject]


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


@dataclass(frozen=True)
class WorkspaceGeneration:
    """One fully constructed state visible to every transport."""

    number: int
    loaded: LoadedProject
    payload: bytes


class Workspace:
    """Hydrate once, retain StrictDoc objects, and replace them atomically."""

    def __init__(
        self,
        project_root: Path,
        state_dir: Path | None = None,
        *,
        loader: Loader = load_project,
    ) -> None:
        self.project_root = find_project_root(project_root)
        self.state_dir = (
            state_dir.expanduser().resolve()
            if state_dir is not None
            else default_state_dir(self.project_root)
        )
        self.output_dir = self.state_dir / "strictdoc-output"
        self._loader = loader
        self._lock = threading.RLock()
        self._current: WorkspaceGeneration | None = None

    def hydrate(self) -> WorkspaceGeneration:
        """Return the current state, constructing generation one if absent."""
        with self._lock:
            if self._current is None:
                self._current = self._load_generation(1)
            return self._current

    def reload(self) -> WorkspaceGeneration:
        """Construct a replacement and publish it only after complete success."""
        with self._lock:
            next_number = 1 if self._current is None else self._current.number + 1
            replacement = self._load_generation(next_number)
            self._current = replacement
            return replacement

    def current(self) -> WorkspaceGeneration:
        return self.hydrate()

    def describe(self) -> dict[str, Any]:
        state = self.current()
        snapshot = state.loaded.snapshot
        return {
            "schema": WORKSPACE_SCHEMA,
            "root": str(self.project_root),
            "stateDir": str(self.state_dir),
            "outputDir": str(self.output_dir),
            "cacheDir": state.loaded.project_config.dir_for_sdoc_cache,
            "generation": state.number,
            "snapshotHash": snapshot["project"]["snapshotHash"],
            "strictdocVersion": snapshot["project"]["strictdocVersion"],
            "loadedAt": snapshot["project"]["loadedAt"],
            "nodes": snapshot["stats"]["nodes"],
            "edges": snapshot["stats"]["edges"],
            "diagnostics": snapshot["stats"]["diagnostics"],
            "hydration": state.loaded.hydration.as_dict(),
        }

    def _load_generation(self, number: int) -> WorkspaceGeneration:
        self.output_dir.mkdir(parents=True, exist_ok=True)
        loaded = self._loader(self.project_root, self.output_dir)
        payload = json.dumps(
            loaded.snapshot, ensure_ascii=False, separators=(",", ":")
        ).encode("utf-8")
        return WorkspaceGeneration(number=number, loaded=loaded, payload=payload)
