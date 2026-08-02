"""Reconcile Nix-owned TOML leaves while preserving runtime-owned siblings.

This is not a general replacement for immutable Nix-managed configuration.
It exists for files where an application must persist required runtime state in
the same document that contains declarative settings. Codex user config is such
a file: its trust prompt calls config/batchWrite on config.toml, so pointing the
whole file at the Nix store makes normal first-run trust persistence fail.

Ownership is deliberately recorded at leaf granularity. Treating a whole TOML
table as managed would let a Nix-declared ``features.memories`` setting erase a
native sibling, or let a declared MCP server erase another server added with
``codex mcp add``. The external manifest also gives removal semantics that a
plain "existing merged with desired" operation cannot provide.
"""

# cspell:ignore fchmod

from __future__ import annotations

import argparse
import json
import os
import stat
import sys
import tempfile
from collections.abc import Mapping, MutableMapping
from pathlib import Path
from typing import Any

import tomlkit


MANIFEST_VERSION = 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    return parser.parse_args()


def desired_leaves(value: Mapping[str, Any]) -> list[tuple[tuple[str, ...], Any]]:
    """Flatten nested desired settings into the exact paths Nix owns."""
    leaves: list[tuple[tuple[str, ...], Any]] = []

    def walk(path: tuple[str, ...], item: Any) -> None:
        if isinstance(item, Mapping):
            for key, child in item.items():
                if not isinstance(key, str):
                    raise ValueError("desired TOML object keys must be strings")
                walk((*path, key), child)
            return
        if not path:
            raise ValueError("desired TOML settings must be an object")
        leaves.append((path, item))

    walk((), value)
    return leaves


def read_manifest(path: Path) -> list[tuple[str, ...]] | None:
    """Read and strictly validate prior ownership before touching config."""
    if not path.exists() and not path.is_symlink():
        return None

    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict) or raw.get("version") != MANIFEST_VERSION:
        raise ValueError(f"unsupported managed-path manifest at {path}")

    paths = raw.get("managed_paths")
    if not isinstance(paths, list):
        raise ValueError(f"invalid managed-path manifest at {path}")

    result: list[tuple[str, ...]] = []
    for item in paths:
        if (
            not isinstance(item, list)
            or not item
            or not all(isinstance(segment, str) for segment in item)
        ):
            raise ValueError(f"invalid managed path in {path}")
        result.append(tuple(item))
    if len(result) != len(set(result)):
        raise ValueError(f"duplicate managed path in {path}")
    return result


def delete_path(root: MutableMapping[str, Any], path: tuple[str, ...]) -> None:
    """Delete one retired leaf and only the empty parent tables it leaves."""
    parents: list[tuple[MutableMapping[str, Any], str]] = []
    current = root
    for segment in path[:-1]:
        child = current.get(segment)
        if not isinstance(child, MutableMapping):
            return
        parents.append((current, segment))
        current = child

    if path[-1] not in current:
        return
    del current[path[-1]]

    for parent, segment in reversed(parents):
        child = parent.get(segment)
        if isinstance(child, MutableMapping) and not child:
            del parent[segment]
        else:
            break


def set_path(root: MutableMapping[str, Any], path: tuple[str, ...], value: Any) -> None:
    """Set one Nix-owned leaf, replacing incompatible scalar/table shapes."""
    current = root
    for segment in path[:-1]:
        child = current.get(segment)
        if not isinstance(child, MutableMapping):
            table = tomlkit.table()
            current[segment] = table
            child = table
        current = child
    current[path[-1]] = value


def atomic_write(path: Path, content: bytes, mode: int) -> None:
    """Replace a file atomically without ever following its destination link."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(
        dir=path.parent,
        prefix=f".{path.name}.nat-tmp.",
    )
    temporary_path = Path(temporary)
    try:
        with os.fdopen(fd, "wb") as handle:
            os.fchmod(handle.fileno(), mode)
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_path, path)
    finally:
        temporary_path.unlink(missing_ok=True)


def write_if_changed(path: Path, content: bytes, mode: int) -> None:
    """Avoid mtime churn, except when replacing the legacy store symlink."""
    is_symlink = path.is_symlink()
    if path.exists() and not is_symlink:
        if not path.is_file():
            raise ValueError(f"refusing to replace non-regular file {path}")
        current = path.read_bytes()
        current_mode = stat.S_IMODE(path.stat().st_mode)
        if current == content:
            if current_mode != mode:
                path.chmod(mode)
            return
    elif not path.exists() and is_symlink:
        raise ValueError(f"refusing to replace dangling symlink {path}")

    atomic_write(path, content, mode)


def reconcile(config_path: Path, manifest_path: Path, desired: Mapping[str, Any]) -> None:
    current_leaves = desired_leaves(desired)
    current_paths = [path for path, _ in current_leaves]
    previous_paths = read_manifest(manifest_path)

    # An empty first generation must leave externally managed config alone. An
    # empty later generation is different: it must use the prior manifest to
    # retract leaves Nix used to own.
    if not current_paths and previous_paths is None:
        return
    if not current_paths and previous_paths == []:
        manifest_path.unlink()
        return

    # Parse both documents before the first write. A malformed native edit or
    # corrupt ownership ledger must fail closed, preserving the original bytes.
    if config_path.exists() or config_path.is_symlink():
        document = tomlkit.parse(config_path.read_text(encoding="utf-8"))
    else:
        document = tomlkit.document()

    # Remove deepest retired paths first so scalar/table transitions are
    # deterministic. Empty-parent pruning never reaches a table that still has
    # a runtime-owned sibling.
    current_path_set = set(current_paths)
    for path in sorted(previous_paths or [], key=lambda item: (-len(item), item)):
        if path not in current_path_set:
            delete_path(document, path)

    for path, value in current_leaves:
        set_path(document, path, value)

    # Config lands before the ledger. If activation is interrupted between the
    # two atomic replacements, the older ledger makes the next run repeat safe,
    # idempotent deletes/sets rather than treating an unrecorded leaf as owned.
    write_if_changed(config_path, tomlkit.dumps(document).encode(), 0o600)

    if current_paths:
        manifest = {
            "managed_paths": [list(path) for path in sorted(current_paths)],
            "version": MANIFEST_VERSION,
        }
        manifest_content = (
            json.dumps(manifest, indent=2, sort_keys=True) + "\n"
        ).encode()
        manifest_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        manifest_path.parent.chmod(0o700)
        write_if_changed(manifest_path, manifest_content, 0o600)
    else:
        manifest_path.unlink(missing_ok=True)


def main() -> None:
    args = parse_args()
    try:
        desired = json.load(sys.stdin)
        if not isinstance(desired, dict):
            raise ValueError("desired TOML settings must be a JSON object")
        reconcile(args.config, args.manifest, desired)
    except (OSError, ValueError) as error:
        # Activation should be loud but concise. A parser traceback obscures
        # the actionable path/error and invites users to ignore HM output as
        # implementation noise; programming errors still escape with a trace.
        print(f"reconcile-toml: {error}", file=sys.stderr)
        raise SystemExit(1) from None


if __name__ == "__main__":
    main()
