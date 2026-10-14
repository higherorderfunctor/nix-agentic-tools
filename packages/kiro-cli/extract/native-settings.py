"""Host-run native settings inventory and repo-readable native keys.

These are native settings reads, separate from the TUI workspace allowlist and UI dispatch.
No account, model request, or inherited user configuration participates.
"""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def extract(binary):
    with tempfile.TemporaryDirectory(prefix="kiro-native-settings-") as temporary:
        root = Path(temporary)
        home, work = root / "home", root / "work"
        home.mkdir()
        work.mkdir()
        env = {
            "CFFIXED_USER_HOME": str(home),
            "HOME": str(home),
            "KIRO_API_KEY": "offline-settings-fixture",
            "KIRO_DISABLE_TELEMETRY": "1",
            "PATH": os.environ.get("PATH", ""),
            "XDG_CACHE_HOME": str(root / "cache"),
            "XDG_CONFIG_HOME": str(root / "config"),
            "XDG_DATA_HOME": str(root / "data"),
        }

        def read():
            result = subprocess.run(
                [binary, "settings", "list", "--all", "--format", "json"],
                cwd=work, env=env, input="", capture_output=True, text=True,
                timeout=30, check=True,
            )
            rows = json.loads(result.stdout)
            assert isinstance(rows, list) and rows, "native settings inventory disappeared"
            assert all(isinstance(row.get("key"), str) for row in rows), rows
            assert len({row["key"] for row in rows}) == len(rows), "duplicate native keys"
            return {row["key"]: row.get("current_value") for row in rows}

        inventory = read()
        # These repo-readable native keys are admitted by the project writer.
        # A broader native census must never widen the separate TUI contract.
        global_values = {"chat.agentEngine": "v3", "chat.ui": "legacy"}
        repo_values = {"chat.agentEngine": "v2", "chat.ui": "tui"}
        for base, values in ((home, global_values), (work, repo_values)):
            target = base / ".kiro/settings/cli.json"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(json.dumps(values))
        selected = read()
        assert all(selected[key] == value for key, value in repo_values.items()), selected
        return {
            "nativeSettingKeys": sorted(inventory),
        }


if __name__ == "__main__":
    print(json.dumps(extract(sys.argv[1]), sort_keys=True))
