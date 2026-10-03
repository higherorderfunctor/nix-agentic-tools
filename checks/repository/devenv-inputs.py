"""Compare local input projections; never fetch or resolve upstream sources."""

import json
from pathlib import Path
import sys

import yaml


def locked_input(lock, name):
    """Resolve root input edges, including follows paths, rather than node names."""
    nodes = lock["nodes"]

    def resolve(edge, seen):
        if isinstance(edge, str):
            return nodes[edge]
        path = tuple(edge)
        if path in seen:
            raise ValueError(f"cyclic follows path: {path}")
        node = nodes[lock["root"]]
        for part in path:
            node = resolve(node["inputs"][part], seen | {path})
        return node

    return resolve(nodes[lock["root"]]["inputs"][name], set())["locked"]


def main():
    committed, expected, flake_path, devenv_path = map(Path, sys.argv[1:])
    errors = []
    if committed.read_bytes() != expected.read_bytes():
        errors.append(
            "DRIFT: devenv.yaml differs from config/generate-devenv-yaml.nix. "
            "Fix: devenv tasks run --mode before generate:devenv-yaml"
        )

    flake = json.loads(flake_path.read_text())
    devenv = json.loads(devenv_path.read_text())
    for name in sorted(yaml.safe_load(committed.read_text())["inputs"]):
        fix = f"Fix: devenv update {name}"
        try:
            flake_locked = locked_input(flake, name)
        except (KeyError, ValueError) as error:
            errors.append(f"DRIFT: {name} missing or invalid in flake.lock: {error}")
            continue
        try:
            devenv_locked = locked_input(devenv, name)
        except (KeyError, ValueError) as error:
            errors.append(f"DRIFT: {name} missing or invalid in devenv.lock: {error}. {fix}")
            continue
        for field in ("rev", "narHash"):
            if devenv_locked.get(field) != flake_locked.get(field):
                errors.append(
                    f"DRIFT: {name} locked {field} differs between devenv.lock "
                    f"and flake.lock. {fix}"
                )
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print("devenv.yaml and devenv.lock agree with flake.lock")
    return 0


if __name__ == "__main__":
    sys.exit(main())
