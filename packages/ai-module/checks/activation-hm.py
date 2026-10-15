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
        environment["DRY_RUN"] = "1"
        for name in ("drain", "write"):
            subprocess.run(
                [bash, "-c", shim + "\n" + fixture[name]],
                env=environment,
                check=True,
                capture_output=True,
                text=True,
            )
            assert not (Path(temporary) / name).exists(), name
        del environment["DRY_RUN"]
        for name, expected in (("drain", "drained"), ("write", "wrote")):
            subprocess.run(
                [bash, "-c", shim + "\n" + fixture[name]],
                env=environment,
                check=True,
                capture_output=True,
                text=True,
            )
            assert (Path(temporary) / name).read_text() == expected
    print("PASS: dry run left no files; enabled and disabled-drain commands executed")


if __name__ == "__main__":
    main()
