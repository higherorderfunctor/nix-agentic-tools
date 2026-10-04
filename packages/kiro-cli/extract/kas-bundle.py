"""Copy out the KAS engine bundle the pinned kiro-cli unpacks on first run.

Usage:  kas-bundle.py <chat-binary> <destination> <cert-file>

`acp --agent-engine v3` starts an agent session immediately, and KAS is unpacked
from the binary into `<data>/kiro-cli/kas/<version>-<hash>/` before that session
needs anything. With a dummy KIRO_API_KEY nothing asks for a login, and the
copy is byte-identical to a logged-in user's (measured on 2.27.1 with `cmp`).

`--v3 chat` does NOT work here: it reaches the TUI, but KAS starts only for an
agent session, so after 60 s it had created an empty `kas/` and nothing in it.
"""

import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from isolated_launch import materialize  # noqa: E402

ENGINE = "node_modules/@kiro/agent/dist/server/acp-server.js"


def engine_bundles(root):
    # The bundle is unpacked into `kas/.incoming-<pid>-<dir>/` and the directory
    # is then renamed into place, so a path under a non-hidden version directory
    # is complete. The hidden staging copy is skipped, never waited on.
    return [
        path
        for path in sorted(root.glob("home/**/kiro-cli/kas/*/" + ENGINE))
        if not path.relative_to(root).parts[-len(Path(ENGINE).parts) - 1].startswith(".")
    ]


binary, destination, cert_file = sys.argv[1:]
with tempfile.TemporaryDirectory(prefix="kiro-kas-") as root:
    materialize(
        binary,
        ["acp", "--agent-engine", "v3"],
        root,
        destination,
        engine_bundles,
        "KAS engine bundle",
        cert_file,
        timeout=180,
    )
