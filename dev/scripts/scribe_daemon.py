#!/usr/bin/env python3
# cspell:ignore sdoc backgrounding
"""The resident scribe: one workspace, one socket, one worktree
(MECH-SCRIBE-DEVENV-PROCESS, docs/plans/scribe-daemon/).

Runs in the FOREGROUND. It does not fork, daemonize, or write a pid file --
devenv's process manager owns the lifecycle, so `devenv up` starts it and
`devenv down` stops it. Backgrounding here would take that away from the
thing that already does it properly.

    scribe-daemon [--root PATH] [--socket PATH]

The root comes from --root, then $SCRIBE_ROOT, then the walk up from the
current directory, and the socket is derived from whichever wins. Hydration
happens BEFORE the socket is bound, so a client never connects to a daemon
that is not ready to answer -- the socket's existence is the readiness
signal, which is what lets a client's "is it up?" check be a connect rather
than a poll.
"""

from __future__ import annotations

import argparse
import signal
import sys
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from scribe_paths import RootError, resolve_root, socket_path  # noqa: E402
from scribe_rpc import build_server  # noqa: E402
from scribe_workspace import Workspace, WorkspaceError  # noqa: E402


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(prog="scribe-daemon", description=__doc__)
    parser.add_argument("--root", help="the workspace to serve (default: $SCRIBE_ROOT, then cwd)")
    parser.add_argument("--socket", help="override the derived socket path")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        root = resolve_root(args.root)
        path = socket_path(root, override=args.socket)
    except RootError as exc:
        print(f"scribe-daemon: {exc}", file=sys.stderr)
        return 1

    workspace = Workspace(root)
    print(f"scribe-daemon: loading {root}", flush=True)
    try:
        state = workspace.current()
    except WorkspaceError as exc:
        print(f"scribe-daemon: {exc}", file=sys.stderr)
        return 1

    try:
        server = build_server(workspace, path)
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"scribe-daemon: {exc}", file=sys.stderr)
        return 1

    described = workspace.describe()
    print(
        f"scribe-daemon: ready on {path} "
        f"({described['nodes']} nodes, {described['documents']} documents, "
        f"generation {state.number})",
        flush=True,
    )

    stopping = threading.Event()

    def stop(_signum, _frame):
        stopping.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)

    try:
        server.serve_forever()
    finally:
        server.server_close()
        print("scribe-daemon: stopped", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
