#!/usr/bin/env python3
# cspell:ignore sdoc sockaddr
"""Where a workspace's socket lives, and how a client finds it without being
told (MECH-SCRIBE-SOCKET-IDENTITY, docs/plans/scribe-daemon/).

Imports nothing from strictdoc, deliberately: a client resolving a socket
path must not pay an interpreter that carries the whole parser.

WHY NOT .devenv
---------------
A sockaddr_un path is capped at 104 bytes, and
<worktree>/.devenv/state/scribe/scribe.sock exceeds it for 24 of the 27
worktrees measured on this machine -- including strictdoc-trial itself at 106
(EV-SCRIBE-SOCKET-PATH-LENGTHS). Every runtime-directory scheme measured fits
in 29 to 62. Durable state still belongs under $DEVENV_STATE; only the socket
moves.

A relative bind would evade the cap entirely -- sun_path resolves against the
process cwd, so chdir plus a bare name is a dozen bytes -- and that stays the
escape hatch if a sandbox ever lacks a runtime directory
(MECH-SCRIBE-SOCKET-IN-SANDBOX). It is not the default because chdir is
process-global and scribe is a library as well as a command.

WHY THE NAME CARRIES BOTH A SLUG AND A DIGEST
---------------------------------------------
The slug is for a person running `ls`: a bare digest tells them nothing about
which workspace they are looking at. The digest is for correctness: worktree
basenames are not reliably unique here (one already nests a `fix/` component),
a branch name is empty or literally HEAD on a detached worktree, and only the
resolved absolute path survives both a branch rename and a directory move.

WHY NOT $DEVENV_STATE AS THE LOOKUP
-----------------------------------
It is set only INSIDE a devenv shell. The most frequent client is an agent
invoking the binary by absolute path with no shell, which would compute a
different answer than the server did and quietly look in the wrong place.
"""

from __future__ import annotations

import hashlib
import os
import re
import tempfile
from pathlib import Path

MARKER = "strictdoc_config.py"
SOCKADDR_LIMIT = 104
_SLUG = re.compile(r"[^A-Za-z0-9._-]+")


class RootError(Exception):
    """No strictdoc project above the path we were given."""


def find_root(start: Path) -> Path:
    """Walk up for the project marker, the way the scribe wrapper does."""
    current = Path(start).expanduser().resolve()
    if current.is_file():
        current = current.parent
    for candidate in (current, *current.parents):
        if (candidate / MARKER).is_file():
            return candidate
    raise RootError(f"no {MARKER} in {start} or any parent -- run inside the repository")


def resolve_root(explicit: str | Path | None = None) -> Path:
    """--root, then SCRIBE_ROOT, then the walk up from the current directory.

    Precedence, not fallback: an explicit root is honored even when the
    current directory sits in a different workspace, which is the whole point
    (DEC-SCRIBE-ROOT-SELECTS-THE-WORKSPACE). A harness launched from a stable
    checkout names the worktree it means.
    """
    if explicit is not None:
        return find_root(Path(explicit))
    from_env = os.environ.get("SCRIBE_ROOT")
    if from_env:
        return find_root(Path(from_env))
    return find_root(Path.cwd())


def workspace_key(root: Path) -> str:
    return hashlib.sha256(str(Path(root).resolve()).encode("utf-8")).hexdigest()[:8]


def workspace_slug(root: Path) -> str:
    cleaned = _SLUG.sub("-", Path(root).resolve().name).strip("-")
    return cleaned or "workspace"


def runtime_dir() -> Path:
    from_env = os.environ.get("XDG_RUNTIME_DIR")
    if from_env:
        return Path(from_env) / "scribe"
    # No runtime directory: fall back to a uid-owned temp directory rather
    # than a world-writable one. Mode and ownership are still checked at bind.
    return Path(tempfile.gettempdir()) / f"scribe-{os.getuid()}"


def socket_path(root: Path, *, override: str | Path | None = None) -> Path:
    """The socket for one workspace. Derived, never configured, so a server
    and a client that never met agree on it."""
    if override is not None:
        return Path(override).expanduser()
    resolved = Path(root).resolve()
    path = runtime_dir() / f"{workspace_slug(resolved)}-{workspace_key(resolved)}.sock"
    encoded = len(os.fsencode(path))
    if encoded >= SOCKADDR_LIMIT:
        raise RootError(
            f"socket path is {encoded} bytes, over the {SOCKADDR_LIMIT}-byte "
            f"limit: {path}. Set XDG_RUNTIME_DIR to something shorter, or pass "
            f"an explicit --socket."
        )
    return path
