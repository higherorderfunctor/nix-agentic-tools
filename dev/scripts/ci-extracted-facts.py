"""Plan Darwin extraction from the Nix owner map, declarations, and derivations."""

import json
import os
from pathlib import Path
import subprocess
import sys


def derivations(root, base=None, names_only=False):
    flake = f"git+{root.as_uri()}?rev={base}" if base else "."
    command = ["timeout", "300", "nix", "eval", "--json"]
    if names_only:
        command.extend(["--apply", "builtins.attrNames"])
    result = subprocess.run(
        [*command, f"{flake}#ciExtractedFacts"],
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
        old = derivations(root, base=base)
        wrapper_changed = subprocess.run(
            ["git", "diff", "--quiet", base, "HEAD", "--", "lib/extracted"],
            cwd=root,
        ).returncode
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
        return derivations(root, names_only=True)


if __name__ == "__main__":
    matrix = plan(Path.cwd(), os.environ["EVENT_NAME"], os.environ.get("BASE_SHA", ""))
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"matrix={json.dumps(matrix, separators=(',', ':'))}\n")
        output.write("planned=true\n")
    print(f"Native extraction matrix: {json.dumps(matrix)}")
