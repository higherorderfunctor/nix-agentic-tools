"""Warn when a Kiro feature needs a global setting devenv cannot write."""

import json
from pathlib import Path
import sys


def global_feature(config_dir, feature, setting):
    settings = config_dir / "settings/cli.json"
    try:
        enabled = json.loads(settings.read_text()).get(setting) is True
    except (OSError, ValueError, AttributeError):
        enabled = False
    if not enabled:
        print(
            f"WARNING: Kiro {feature} requested by ai.kiro.cli.{feature}.enable, but "
            f"devenv cannot enable its global setting: {settings} does not set "
            f"{setting}=true. Configure ai.kiro.cli.native.settings.{setting} "
            "in Home Manager; the project setting is not honored.",
            file=sys.stderr,
        )


if __name__ == "__main__":
    global_feature(Path(sys.argv[1]), sys.argv[2], sys.argv[3])
