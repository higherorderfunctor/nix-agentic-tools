#!/usr/bin/env python3
"""Own one resident StrictDoc project and publish immutable generations."""

from __future__ import annotations

import json
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

from paths import default_state_dir, find_project_root
from snapshot import LoadedProject, load_project

WORKSPACE_SCHEMA = "sdoc-board-workspace/1"
Loader = Callable[[Path, Path], LoadedProject]


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
