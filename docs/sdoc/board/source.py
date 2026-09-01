#!/usr/bin/env python3
"""The board's one data source: the resident scribe daemon.

The daemon holds the loaded graph and reconciles it on every read -- its own
content hash notices an edit, a checkout, a rebase -- so "fresh" here means
"whatever the daemon serves right now", with no exporter subprocess and no
second in-process StrictDoc load. `workspace.export` writes StrictDoc's own
JSON export from the held graph (~0.3 s against ~2.3 s for the one-shot
command, byte-identical), and the export lands under `output/`, which both
the daemon's freshness sweep and the UID walk skip, so exporting never dirties
the thing being exported.

FAIL CLOSED, LOUDLY. When no daemon answers, requests surface the client's
own refusal -- the socket and the command that starts one -- instead of
falling back to a slow in-process load (DEC-SCRIBE-DAEMON-NO-FALLBACK; the
browser renders the remedy). The payloads are cached per daemon generation:
a repeat request while nothing changed re-serves the adapted JSON without
re-exporting.
"""

from __future__ import annotations

import json
import sys
import threading
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(REPO_ROOT / "dev" / "scripts"))

from scribe_client import ClientError, NoDaemon, call_for_root  # noqa: E402,F401

from adapter import adapt, load_index, parse_sgra, uid_paths  # noqa: E402


@dataclass(frozen=True)
class Payloads:
    """One adapted generation: the two JSON bodies the API serves."""

    generation: int
    snapshot: bytes
    rows: bytes


class DaemonSource:
    """Ask the daemon what generation it holds; re-adapt only on change."""

    def __init__(self, root: Path, *, socket_override=None) -> None:
        self.root = Path(root).resolve()
        self.export_dir = self.root / "output" / "board" / "export"
        self.grammar_path = self.root / "docs" / "sdoc" / "grammar.sgra"
        self._socket_override = socket_override
        self._lock = threading.Lock()
        self._cached: Payloads | None = None

    def describe(self) -> dict:
        return self._call("workspace.describe")

    def payloads(self) -> Payloads:
        with self._lock:
            described = self._call("workspace.describe")
            cached = self._cached
            if (
                cached is not None
                and not described.get("dirty")
                and described.get("generation") == cached.generation
            ):
                return cached

            exported = self._call(
                "workspace.export", {"outputDir": str(self.export_dir)}
            )
            index = load_index(Path(exported["index"]))
            project = {
                "name": self.root.name,
                "root": str(self.root),
                "generation": exported["generation"],
            }
            adapted = adapt(
                index,
                uid_paths(self.root),
                parse_sgra(self.grammar_path),
                project,
            )
            self._cached = Payloads(
                generation=exported["generation"],
                snapshot=_encode(adapted["snapshot"]),
                rows=_encode(adapted["rows"]),
            )
            return self._cached

    def _call(self, method: str, params: dict | None = None) -> dict:
        return call_for_root(
            self.root, method, params, override=self._socket_override
        )


def _encode(payload: dict) -> bytes:
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode(
        "utf-8"
    )
