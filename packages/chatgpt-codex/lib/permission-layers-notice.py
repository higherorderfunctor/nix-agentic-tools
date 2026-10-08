"""Warn about opposite permission models in user and delivered project config."""

import sys
import tomllib
from pathlib import Path


def read_config(path):
    try:
        with path.open("rb") as stream:
            return tomllib.load(stream)
    except (OSError, ValueError):
        return None


def model(config):
    legacy = "sandbox_mode" in config or "sandbox_workspace_write" in config
    named = "default_permissions" in config or bool(config.get("permissions"))
    if legacy != named:
        return "legacy sandbox" if legacy else "named permissions"
    return None


project_path, user_path = map(Path, sys.argv[1:])
project, user = read_config(project_path), read_config(user_path)
if project is not None and user is not None:
    project_model, user_model = model(project), model(user)
    if project_model and user_model and project_model != user_model:
        # Codex resolves selectors low-to-high; a table alone is not a selector.
        winner = project_path if project_model == "named permissions" else user_path
        winning_model = "named permissions"
        for path, config, layer_model in (
            (user_path, user, user_model),
            (project_path, project, project_model),
        ):
            if "sandbox_mode" in config or "default_permissions" in config:
                winner, winning_model = path, layer_model
        print(
            f"warning: Codex permission models differ: {user_path} uses {user_model}; "
            f"{project_path} uses {project_model}. When the project config is trusted "
            f"and loaded, {winner}'s {winning_model} wins; the other model is ignored. "
            "Use one permission model across both files.",
            file=sys.stderr,
        )
