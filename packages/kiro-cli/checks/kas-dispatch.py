"""Real native launcher/direct-chat dispatch: package binding beats old caches."""

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location("kas_smoke", sys.argv[2])
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)
variants = json.loads(Path(sys.argv[1]).read_text())

def capture_node(root):
    capture, node = root / "capture.json", root / "node"
    node.write_text("#!" + sys.executable + "\nimport json,os,sys\nfrom pathlib import Path\nPath(" + repr(str(capture)) + ").write_text(json.dumps(sys.argv))\nPath(" + repr(str(root / "capture-env.json")) + ").write_text(json.dumps({\"KIRO_HOME\": os.environ.get(\"KIRO_HOME\")}))\n")
    node.chmod(0o755)
    return capture, node


for name, variant in variants.items():
    for stale in (False, True):
        for command in ("kiro-cli", "kiro-cli-chat"):
            for mode in ("chat", "acp"):
                with tempfile.TemporaryDirectory() as tmp:
                    root = Path(tmp)
                    home, work = root / "home", root / "work"
                    home.mkdir()
                    work.mkdir()
                    old = home / ".local/share/kiro-cli/kas/0.1.0-old/node_modules/@kiro/agent/dist/server/acp-server.js"
                    if stale:
                        old.parent.mkdir(parents=True)
                        old.write_text("throw Error('stale KAS selected');")
                    capture, node = capture_node(root)
                    env = {"PATH": variant["package"] + "/bin:" + os.environ["PATH"],
                           "HOME": str(home), "CFFIXED_USER_HOME": str(home), "KIRO_HOME": str(root / "kiro-home"),
                           "XDG_CACHE_HOME": str(root / "cache"), "XDG_CONFIG_HOME": str(root / "config"),
                           "KIRO_KAS_NODE_PATH": str(node), "KIRO_DISABLE_TELEMETRY": "1",
                           "KIRO_API_KEY": "offline-dispatch-fixture", "TERM": "dumb"}
                    args = [variant["package"] + "/bin/" + command, mode]
                    settings = home / ".kiro/settings/cli.json"
                    settings.parent.mkdir(parents=True, exist_ok=True)
                    settings.write_text(json.dumps({"chat.agentEngine": "v2"}))
                    kiro_settings = root / "kiro-home/settings/cli.json"
                    kiro_settings.parent.mkdir(parents=True)
                    kiro_settings.write_text(settings.read_text())
                    repo_settings = work / ".kiro/settings/cli.json"
                    repo_settings.parent.mkdir(parents=True)
                    repo_settings.write_text(json.dumps({"chat.agentEngine": "v3"}))
                    if mode == "chat":
                        args += ["--no-interactive", "--model", "nix-no-such-model", "offline dispatch fixture"]
                    result = subprocess.run(args, env=env, cwd=work, input="", capture_output=True, text=True, timeout=30)
                    assert capture.exists(), (name, stale, args, result.returncode, result.stderr)
                    argv = json.loads(capture.read_text())
                    assert variant["server"] in argv, (name, stale, args, argv)
                    assert json.loads((root / "capture-env.json").read_text())["KIRO_HOME"] == str(root / "kiro-home"), (command, mode, "KIRO_HOME handoff")
                    assert list(home.glob("**/kas/*/node_modules/@kiro/agent/dist/server/acp-server.js")) == ([old] if stale else []), "unexpected cache extraction"
    # Every payload selects its packaged server and warns once about overrides.
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        capture, node = capture_node(root)
        override = root / "override.js"
        override.write_text("// explicit override")
        env = {"PATH": variant["package"] + "/bin:" + os.environ["PATH"], "HOME": tmp,
               "CFFIXED_USER_HOME": tmp, "KIRO_KAS_NODE_PATH": str(node),
               "KIRO_KAS_SERVER_PATH": str(override), "KIRO_API_KEY": "offline-dispatch-fixture"}
        settings = root / ".kiro/settings/cli.json"
        settings.parent.mkdir(parents=True)
        settings.write_text(json.dumps({"chat.agentEngine": "v3"}))
        warning = "kiro-cli: inherited KIRO_KAS_SERVER_PATH detected and ignored; using " + variant["server"]
        for inherited in (None, variant["server"], "", str(override)):
            if inherited is None:
                env.pop("KIRO_KAS_SERVER_PATH", None)
            else:
                env["KIRO_KAS_SERVER_PATH"] = inherited
            for command in ("kiro-cli", "kiro-cli-chat"):
                capture.unlink(missing_ok=True)
                result = subprocess.run([variant["package"] + "/bin/" + command, "acp"], env=env, cwd=tmp,
                                        input="", capture_output=True, text=True, timeout=30)
                assert variant["server"] in json.loads(capture.read_text()), (name, command, "override precedence")
                expected_warnings = int(inherited is not None and inherited != variant["server"])
                assert result.stderr.splitlines().count(warning) == expected_warnings, result.stderr
        # An explicit v2 choice beats the package ACP default. Its own
        # validation error is before auth/network and before any KAS process.
        capture.unlink()
        for command in ("kiro-cli", "kiro-cli-chat"):
            for flags in (["--agent-engine=v2"], ["--agent-engine", "v2"]):
                result = subprocess.run([variant["package"] + "/bin/" + command, "acp", *flags, "--auth-method", "client"],
                                        env=env, cwd=tmp, input="", capture_output=True, text=True, timeout=30)
                assert result.returncode == 2 and "only supported with --agent-engine=v3" in result.stderr, result.stderr
                assert not capture.exists(), "explicit v2 started KAS"
        # Defaults remain idempotent with explicit flags and a trailing --.
        for command, flags in (("kiro-cli", ["--v3", "acp"]),
                               ("kiro-cli-chat", ["acp", "--agent-engine=v3"]),
                               ("kiro-cli-chat", ["acp", "--"]),
                               ("kiro-cli-chat", ["--cloud", "acp"])):
            capture.unlink(missing_ok=True)
            result = subprocess.run([variant["package"] + "/bin/" + command, *flags],
                                    env=env, cwd=tmp, input="", capture_output=True, text=True, timeout=30)
            assert result.returncode == 0 and capture.exists(), (command, flags, result.stderr)
        # Remove both overrides and initialize through native ACP with real Node.
        del env["KIRO_KAS_NODE_PATH"]
        del env["KIRO_KAS_SERVER_PATH"]
        smoke.initialize([variant["package"] + "/bin/kiro-cli", "acp"], env)
    print(f"PASS: {name}: launcher/direct chat, CLI/ACP, fresh/stale cache, explicit overrides/v2, real ACP initialize", flush=True)
