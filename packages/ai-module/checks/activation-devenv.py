"""Execute emitted devenv tasks and check both exit paths."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    fixture = json.loads(
        sys.stdin.read() if sys.argv[1] == "-" else Path(sys.argv[1]).read_text()
    )
    bash = sys.argv[2] if len(sys.argv) > 2 else "bash"
    with tempfile.TemporaryDirectory() as temporary:
        environment = os.environ.copy()
        environment["DEVENV_ROOT"] = temporary
        for name in ("prune", "success"):
            result = subprocess.run(
                [bash, "-c", fixture[name]],
                env=environment,
                capture_output=True,
                text=True,
            )
            assert result.returncode == 0, (name, result.stderr)
        assert (Path(temporary) / "pruned").read_text() == "pruned"
        assert (Path(temporary) / "success").read_text() == "success"
        result = subprocess.run(
            [bash, "-c", fixture["failure"]],
            env=environment,
            capture_output=True,
            text=True,
        )
        assert result.returncode != 0, result
        assert (Path(temporary) / "failure-started").read_text() == "started"
        assert not (Path(temporary) / "failure-escaped").exists()
    print("PASS: task success, disabled drain, and failure propagation")


if __name__ == "__main__":
    main()
