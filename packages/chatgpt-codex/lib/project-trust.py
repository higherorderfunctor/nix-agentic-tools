"""Resolve Codex project trust for both shell-entry notices."""

import subprocess
import sys
import tomllib
from pathlib import Path


def resolve(directory, user_path, git):
    try:
        with Path(user_path).open("rb") as stream:
            projects = tomllib.load(stream).get("projects", {})
        if not isinstance(projects, dict):
            return "unknown"
        common = subprocess.run(
            [git, "-C", directory, "rev-parse", "--path-format=absolute", "--git-common-dir"],
            capture_output=True, text=True, check=False,
        )
        candidates = [Path(directory)]
        if common.returncode == 0:
            candidates.append(Path(common.stdout.strip()).parent)
        # Codex checks canonical/original cwd before the main checkout;
        # an explicit cwd entry without trust also prevents falling through.
        for candidate in candidates:
            for key in (str(candidate.resolve()), str(candidate)):
                if key in projects:
                    entry = projects[key]
                    if not isinstance(entry, dict):
                        return "unknown"
                    return "trusted" if entry.get("trust_level") == "trusted" else "untrusted"
        return "untrusted"
    except (OSError, ValueError):
        return "unknown"


print(resolve(*sys.argv[1:]))
