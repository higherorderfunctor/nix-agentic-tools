"""Plan native extraction from the declarations consumed by mkOwnerCheck."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


SYSTEM = "aarch64-darwin"


def owners(root):
    found = []
    for path in sorted(Path(root).glob("packages/*/extracted/facts.json")):
        try:
            facts = json.loads(path.read_text())
            needed = any(
                row["source"] == "host-run" and SYSTEM in row.get("systems", [SYSTEM])
                for row in facts.values()
            )
        except (AttributeError, KeyError, OSError, TypeError, ValueError):
            needed = True
        if needed:
            found.append(path.parent.parent.name)
    return found


def derivations(root, names):
    expression = (
        "packages: builtins.listToAttrs (map (name: { inherit name; "
        "value = { inherit (packages.${name}.passthru.extracted) drvPath system; }; "
        "}) (builtins.fromJSON " + json.dumps(json.dumps(names)) + "))"
    )
    result = subprocess.run(
        ["timeout", "300", "nix", "eval", "--json", f".#ciPackages.{SYSTEM}", "--apply", expression],
        cwd=root,
        capture_output=True,
        check=True,
        text=True,
        timeout=300,
    )
    return json.loads(result.stdout)


def plan(root, event, base):
    current = owners(root)
    try:
        head = derivations(root, current)
        native = [name for name in current if head[name]["system"] == SYSTEM]
        if event == "workflow_dispatch":
            return native
        if not base or set(base) == {"0"}:
            return native
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
                previous = owners(base_root)
                old = derivations(base_root, [name for name in native if name in previous])
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
            name
            for name in native
            if wrapper_changed or name not in previous or head[name]["drvPath"] != old[name]["drvPath"]
        ]
    except (OSError, RuntimeError, subprocess.CalledProcessError, subprocess.TimeoutExpired, ValueError) as error:
        print(f"Native extraction comparison unavailable; running every host-run owner: {error}", file=sys.stderr)
        return current


if __name__ == "__main__":
    matrix = plan(Path.cwd(), os.environ["EVENT_NAME"], os.environ.get("BASE_SHA", ""))
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as output:
        output.write(f"matrix={json.dumps(matrix, separators=(',', ':'))}\n")
        output.write("planned=true\n")
    print(f"Native extraction matrix: {json.dumps(matrix)}")
