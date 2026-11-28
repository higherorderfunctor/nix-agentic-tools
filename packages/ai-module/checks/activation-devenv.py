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
        # A normal task must execute; pruning must execute even with its owner off.
        for name, marker in (("prune", "pruned"), ("success", "success")):
            result = subprocess.run(
                [bash, "-c", fixture[name]],
                env=environment,
                capture_output=True,
                text=True,
            )
            assert result.returncode == 0, (name, result.stderr)
            assert (Path(temporary) / marker).read_text() == marker
        # A mid-task failure must propagate, not run the trailing command.
        result = subprocess.run(
            [bash, "-c", fixture["failure"]],
            env=environment,
            capture_output=True,
            text=True,
        )
        assert result.returncode == 1, result
        assert (Path(temporary) / "failure-started").read_text() == "started"
        assert not (Path(temporary) / "failure-escaped").exists()
    print("PASS: task success, disabled drain, and failure propagation")


if __name__ == "__main__":
    main()
