"""Shared local resolver for Codex's document budget and project trust."""

from copy import deepcopy
import json
import os
from pathlib import Path
import subprocess
import sys
import tomllib


def read_config(path):
    try:
        with path.open("rb") as source:
            return tomllib.load(source)
    except OSError:
        return {}


def merge(base, extra):
    for key, value in extra.items():
        if isinstance(value, dict) and isinstance(base.get(key), dict):
            merge(base[key], value)
        else:
            base[key] = value
    return base


def resolve(git, directory, default, overrides=(), profile=None):
    directory = Path(directory).expanduser().resolve()
    codex_home = Path(os.environ.get("CODEX_HOME") or str(Path.home() / ".codex")).resolve()
    user_config = codex_home / "config.toml"
    config = merge(read_config(Path("/etc/codex/config.toml")), read_config(user_config))
    if profile:
        # Codex profiles are single filenames, never arbitrary paths.
        if profile in {".", ".."} or "/" in profile or "\\" in profile:
            raise ValueError("invalid profile filename")
        merge(config, read_config(codex_home / f"{profile}.config.toml"))
    session = {}
    for override in overrides:
        key, value = override.split("=", 1)
        try:
            parsed = tomllib.loads(override)
        except ValueError:
            parsed = tomllib.loads(f"{key}={json.dumps(value)}")
        merge(session, parsed)
    discovery = merge(deepcopy(config), session)
    # Managed local settings have higher precedence than session flags.
    managed = read_config(Path("/etc/codex/managed_config.toml"))
    merge(discovery, managed)
    markers = discovery.get("project_root_markers", [".git"])
    root = next((folder for folder in (directory, *directory.parents) if any((folder / marker).exists() for marker in markers)), directory)
    result = subprocess.run(
        [git, "-c", "core.fsmonitor=false", "-C", str(directory), "rev-parse", "--path-format=absolute", "--git-common-dir"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, check=False,
    )
    main_checkout = Path(result.stdout.strip()).parent if result.returncode == 0 else None
    projects = discovery.get("projects", {})

    def trust(folder):
        # Directory entry, configured root, then clone root; the last route
        # lets linked worktrees inherit the main checkout's trust.
        for path in (folder, root, main_checkout):
            if path is None:
                continue
            entry = projects.get(str(path), {})
            if entry.get("trust_level") in {"trusted", "untrusted"}:
                return entry["trust_level"]
        return None

    chain = []
    cursor = directory
    while True:
        chain.append(cursor)
        if cursor == root:
            break
        cursor = cursor.parent
    chain.reverse()
    skipped = []
    for folder in chain:
        project_config = folder / ".codex/config.toml"
        if project_config == user_config:
            continue
        project = read_config(project_config)
        if trust(folder) == "trusted":
            # These keys are ignored at project scope by Codex. In particular
            # a project cannot establish its own trust or change the root walk.
            project.pop("projects", None)
            project.pop("project_root_markers", None)
            merge(config, project)
        else:
            limit = project.get("project_doc_max_bytes")
            if isinstance(limit, int) and not isinstance(limit, bool):
                skipped.append((project_config, limit))
    merge(config, session)
    merge(config, managed)
    effective = config.get("project_doc_max_bytes", default)
    if not isinstance(effective, int) or isinstance(effective, bool) or effective < 0:
        raise ValueError("invalid project_doc_max_bytes")
    names = ["AGENTS.override.md", "AGENTS.md"]
    for name in config.get("project_doc_fallback_filenames", []):
        # Upstream POSIX candidate_filenames rejects these concrete inputs.
        if name and name not in {".", ".."} and "/" not in name and "\0" not in name and name not in names:
            names.append(name)
    # Active-project distrust suppresses docs using cwd and the Git clone root,
    # not the custom marker root used to gate project configuration layers.
    doc_trust = next((projects[str(path)]["trust_level"] for path in (directory, main_checkout) if path is not None and projects.get(str(path), {}).get("trust_level") in {"trusted", "untrusted"}), None)
    return {
        "directories": [str(folder) for folder in chain],
        "filenames": names,
        "limit": effective,
        # The trust of each walked directory, so a caller warning about every
        # project layer resolves once.
        "directory_trust": {str(folder): trust(folder) or "untrusted" for folder in chain},
        "untrusted": doc_trust == "untrusted",
        "untrusted_config": next((str(path) for path, limit in reversed(skipped) if limit > effective), None),
        "user_config": str(user_config),
    }


if __name__ == "__main__":
    git, directory, default, *arguments = sys.argv[1:]
    mode = arguments[0] if arguments[:1] == ["--json"] else None
    arguments = arguments[1:] if mode else arguments
    overrides = []
    profile = None
    for index in range(0, len(arguments), 2):
        if arguments[index] in {"-c", "--config"}:
            overrides.append(arguments[index + 1])
        elif arguments[index] in {"-p", "--profile"}:
            profile = arguments[index + 1]
    resolution = resolve(git, directory, int(default), overrides, profile)
    print(json.dumps(resolution) if mode == "--json" else resolution["limit"])
