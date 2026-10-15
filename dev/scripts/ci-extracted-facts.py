"""Plan Darwin extraction from the Nix owner map, declarations, and derivations."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


PLAN = Path(__file__).resolve().parents[2] / "checks/extracted/ci-plan.nix"


def derivations(root, include_derivations=True):
    expression = (
        "let root = builtins.toPath "
        + json.dumps(str(root))
        + "; flake = builtins.getFlake (toString root); in import (builtins.toPath "
        + json.dumps(str(PLAN))
        + ") { inherit flake root; derivations = "
        + ("true" if include_derivations else "false")
        + "; }"
    )
    result = subprocess.run(
        ["timeout", "300", "nix", "eval", "--json", "--impure", "--expr", expression],
        cwd=root,
        capture_output=True,
        check=True,
        text=True,
        timeout=300,
    )
    return json.loads(result.stdout)


def report_failure(error):
    print(f"Native extraction comparison unavailable; running every host-run owner: {error}", file=sys.stderr)
    stderr = getattr(error, "stderr", None)
    if stderr:
        if isinstance(stderr, bytes):
            stderr = stderr.decode(errors="replace")
        print(stderr, end="" if stderr.endswith("\n") else "\n", file=sys.stderr)


def plan(root, event, base):
    head = None
    try:
        head = derivations(root)
        current = list(head)
        if event == "workflow_dispatch" or not base or set(base) == {"0"}:
            return current
        with tempfile.TemporaryDirectory() as temporary:
            base_root = Path(temporary) / "base"
            subprocess.run(
                ["git", "worktree", "add", "--detach", str(base_root), base],
                cwd=root,
                check=True,
                capture_output=True,
                text=True,
            )
            try:
                old = derivations(base_root)
                wrapper_changed = subprocess.run(
                    ["git", "diff", "--quiet", base, "HEAD", "--", "lib/extracted"],
                    cwd=root,
                ).returncode
            finally:
                subprocess.run(
                    ["git", "worktree", "remove", "--force", str(base_root)],
                    cwd=root,
                    check=True,
                )
        if wrapper_changed not in (0, 1):
            raise RuntimeError("cannot compare lib/extracted with base")
        return [
            name for name in current if wrapper_changed or name not in old or head[name]["drvPath"] != old[name]["drvPath"]
        ]
    except (OSError, RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError) as error:
        report_failure(error)
        if head is not None:
            return list(head)
        # A derivation evaluation can fail while declarations remain readable.
        return list(derivations(root, include_derivations=False))


if __name__ == "__main__":
    matrix = plan(Path.cwd(), os.environ["EVENT_NAME"], os.environ.get("BASE_SHA", ""))
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"matrix={json.dumps(matrix, separators=(',', ':'))}\n")
        output.write("planned=true\n")
    print(f"Native extraction matrix: {json.dumps(matrix)}")
