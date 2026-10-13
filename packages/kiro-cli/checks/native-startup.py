"""Offline native engine selection through both supported entry points."""

import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile

package = sys.argv[1]
for command in ("kiro-cli", "kiro-cli-chat"):
    # A repository named acp is a global option value, not the subcommand.
    with tempfile.TemporaryDirectory() as temporary:
        env = {"PATH": package + "/bin:" + os.environ["PATH"],
               "HOME": temporary, "CFFIXED_USER_HOME": temporary,
               "KIRO_DISABLE_TELEMETRY": "1", "TERM": "dumb"}
        for flags in (["--repo", "acp"], ["--repo=acp"]):
            result = subprocess.run(
                [package + "/bin/" + command, *flags, "settings", "list", "--all", "--format", "json"],
                cwd=temporary, env=env, capture_output=True, text=True, timeout=30)
            if command == "kiro-cli-chat":
                assert result.returncode == 0, result.stderr
                assert any(row["key"] == "chat.agentEngine" for row in json.loads(result.stdout))
            else:
                assert result.returncode == 2 and "requires '--cloud'" in result.stderr, result.stderr
            assert "--agent-engine" not in result.stderr, result.stderr
            print(f"PASS: {command}: repository value {flags}", flush=True)
    if "--globals-only" in sys.argv:
        continue
    cases = [
        ("repo-v1", "v3", "v1", [], "V1"),
        ("global-default", "v3", None, [], "Kas"),
        ("repo-v2", "v3", "v2", [], "V2"),
        ("repo-v3", "v2", "v3", [], "Kas"),
        ("explicit-v3", "v3", "v2", ["--v3"], "Kas"),
        ("explicit-v2", "v3", "v3", ["--v2"], "V2"),
        ("explicit-engine-v2", "v3", "v3", ["--agent-engine=v2"], "V2"),
    ]
    for name, global_engine, repo_engine, flags, expected in cases:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            home, work = root / "home", root / "work"
            for base, engine in ((home, global_engine), (work, repo_engine)):
                (base / ".kiro/settings").mkdir(parents=True)
                if engine is not None:
                    (base / ".kiro/settings/cli.json").write_text(json.dumps({"chat.agentEngine": engine}))
            log = root / "chat.log"
            env = {
                "PATH": package + "/bin:" + os.environ["PATH"],
                "HOME": str(home), "CFFIXED_USER_HOME": str(home),
                "XDG_CACHE_HOME": str(root / "cache"),
                "XDG_CONFIG_HOME": str(root / "config"),
                "XDG_DATA_HOME": str(root / "data"),
                "KIRO_API_KEY": "offline-startup-fixture",
                "KIRO_CHAT_LOG_FILE": str(log), "KIRO_LOG_LEVEL": "debug",
                "KIRO_DISABLE_TELEMETRY": "1", "TERM": "dumb",
            }
            args = [package + "/bin/" + command, "chat", *flags, "--no-interactive"]
            result = subprocess.run(args, cwd=work, env=env, input="", capture_output=True, text=True, timeout=30)
            assert result.returncode == 1 and "Input must be supplied" in result.stderr, (args, result.stderr)
            decisions = [re.sub(r"\x1b\[[0-9;]*m", "", line) for line in log.read_text().splitlines() if "launch decision" in line]
            assert any("launch decision engine=" + expected in line for line in decisions), (args, decisions)
            print(f"PASS: {command}: {name}: {expected}", flush=True)
