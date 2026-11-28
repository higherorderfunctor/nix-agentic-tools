"""Exercise the emitted activation body with Home Manager's run helper."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    fixture = json.loads(sys.stdin.read() if sys.argv[1] == "-" else Path(sys.argv[1]).read_text())
    bash, shim = sys.argv[2], Path(sys.argv[3]).read_text()
    with tempfile.TemporaryDirectory() as temporary:
        environment = os.environ.copy()
        environment["HOME"] = temporary
        # Dry run must suppress the disabled-owner drain.
        environment.pop("DRY_RUN", None)
        for name, expected in (("drain", None), ("drain", "drained")):
            dry_run = {"DRY_RUN": "1"} if expected is None else {}
            subprocess.run(
                [bash, "-c", shim + "\n" + fixture[name]],
                env=environment | dry_run,
                check=True,
                capture_output=True,
                text=True,
            )
            target = Path(temporary) / name
            if expected is None:
                assert not target.exists(), name
            else:
                assert target.read_text() == expected, name
    print("PASS: dry run suppressed the drain; normal activation executed it")


if __name__ == "__main__":
    main()
