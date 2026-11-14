"""Collect credential observations for callers of the allowance normalizer.

Library callers parse a Manifest, then collect() returns the normalizer's Snapshot.
The routing helper owns execution, retries and timeouts; captures retain each
credential's attribution and every route. Owner tests are the first caller.
"""

from datetime import datetime, timezone
from pathlib import Path
import runpy
import subprocess
import types

from pydantic import TypeAdapter

# Load sibling source files without consulting installed modules or bytecode caches.
SCRIPTS = Path(__file__).parent
normalizer = types.SimpleNamespace(**runpy.run_path(str(SCRIPTS / "usage-normalize.py")))
planner = types.SimpleNamespace(**runpy.run_path(str(SCRIPTS / "delegate-routing-plan.py")))


class ReaderRegistration(normalizer.Registration):
    """Add the command to the normalizer's validated credential/window binding."""
    command: normalizer.Nonempty | None


class Manifest(normalizer.Snapshot):
    """Use the snapshot's route and scope checks before executing any command."""
    pools: dict[str, ReaderRegistration]
    readers: dict[str, normalizer.Capture] = {}


def collect(manifest: Manifest, now: str, reader_shell: str, *,
            clock=lambda: datetime.now(timezone.utc), run=planner.run_reader) -> normalizer.Snapshot:
    """Capture each distinct command once, sharing the helper's retry policy."""
    instant = TypeAdapter(normalizer.Timestamp).validate_python(now)
    captures = {}

    def capture(argv, **kwargs):
        try:
            process = run(argv, **kwargs)
        except (OSError, subprocess.TimeoutExpired, UnicodeError) as error:
            # Fixed statuses cross the diagnostic boundary; exception text never does.
            status = (65 if isinstance(error, UnicodeError) else
                      124 if isinstance(error, subprocess.TimeoutExpired) else 127)
            process = subprocess.CompletedProcess(argv, status, "")
        captures[command] = normalizer.Capture(
            exit=process.returncode, finishedAt=clock().isoformat(), stdout=process.stdout)
        # The helper only decides retry here; the normalizer alone parses the payload.
        return subprocess.CompletedProcess(argv, process.returncode, "{}")

    readers = {
        credential: registration.command.replace("<now-ms>", str(int(instant.timestamp() * 1000)))
        for credential, registration in sorted(manifest.pools.items())
        if registration.command is not None
    }
    for command in dict.fromkeys(readers.values()):
        planner.collect([{"command": command, "name": command}], int(instant.timestamp()),
                        reader_shell, run=capture)
    return normalizer.Snapshot(
        pools=manifest.pools, routes=manifest.routes, runtime=manifest.runtime,
        readers={credential: captures[command] for credential, command in readers.items()})
