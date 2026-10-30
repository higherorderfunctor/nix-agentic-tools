"""Plan native extraction from the Nix owner map, declarations, and derivations."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def derivations(root, system, base=None, names_only=False):
    flake = f"git+{root.as_uri()}?rev={base}" if base else "."
    command = ["timeout", "300", "nix", "eval", "--json"]
    if names_only:
        command.extend(["--apply", "builtins.attrNames"])
    if names_only and system == "x86_64-linux":
        # A broken Linux owner check must not prevent recovering its name.
        command.extend(["--file", "checks/extracted/owners.nix"])
    else:
        command.append(f"{flake}#ciExtractedFacts.{system}")
    result = subprocess.run(
        command,
        cwd=root,
        capture_output=True,
        check=True,
        text=True,
        timeout=300,
    )
    return json.loads(result.stdout)


def report_failure(error):
    print(f"Native extraction comparison unavailable; running every selected owner: {error}", file=sys.stderr)
    stderr = getattr(error, "stderr", None)
    if stderr:
        if isinstance(stderr, bytes):
            stderr = stderr.decode(errors="replace")
        print(stderr, end="" if stderr.endswith("\n") else "\n", file=sys.stderr)


def plan(root, system, event, base):
    head = None
    try:
        head = derivations(root, system)
        current = list(head)
        if event == "workflow_dispatch" or not base or set(base) == {"0"}:
            return current
        old = derivations(root, system, base=base)
        wrapper_changed = subprocess.run(
            ["git", "diff", "--quiet", base, "HEAD", "--", "lib/extracted"],
            cwd=root,
        ).returncode
        if wrapper_changed not in (0, 1):
            raise RuntimeError("cannot compare lib/extracted with base")
        return [
            name for name in current if wrapper_changed or name not in old or head[name] != old[name]
        ]
    except (OSError, RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError) as error:
        report_failure(error)
        if head is not None:
            return list(head)
        # A derivation evaluation can fail while declarations remain readable.
        return derivations(root, system, names_only=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("system", choices=("aarch64-darwin", "x86_64-linux"))
    args = parser.parse_args()
    matrix = plan(Path.cwd(), args.system, os.environ["EVENT_NAME"], os.environ.get("BASE_SHA", ""))
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"matrix={json.dumps(matrix, separators=(',', ':'))}\n")
    print(f"Native extraction matrix ({args.system}): {json.dumps(matrix)}")
