"""Real native dispatch through both commands: package binding beats old caches.

The `trusted` variant also proves, on the real binary, that KAS starts with the
wrapper's `--trust-tools` gate in place and never receives the grant in its own
argv in either mode, and the stock variant's
raw measurements pin the binary behavior that gate is built on.
"""

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
    node.write_text("#!" + sys.executable + "\nimport json,sys\nfrom pathlib import Path\nPath(" + repr(str(capture)) + ").write_text(json.dumps(sys.argv))\n")
    node.chmod(0o755)
    return capture, node


def offline_env(root, bin_dir, node):
    home = root / "home"
    home.mkdir(exist_ok=True)
    return {"PATH": bin_dir + ":" + os.environ["PATH"],
            "HOME": str(home), "CFFIXED_USER_HOME": str(home),
            "XDG_CACHE_HOME": str(root / "cache"), "XDG_CONFIG_HOME": str(root / "config"),
            "KIRO_KAS_NODE_PATH": str(node), "KIRO_DISABLE_TELEMETRY": "1",
            "KIRO_API_KEY": "offline-dispatch-fixture", "TERM": "dumb"}


def raw(binary, arguments):
    """Run the stock binary's own wrapper with no managed argv injection."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        capture, node = capture_node(root)
        work = root / "work"
        work.mkdir()
        result = subprocess.run([binary, *arguments], env=offline_env(root, str(Path(binary).parent), node),
                                cwd=work, input="", capture_output=True, text=True, timeout=30)
        return result, capture.exists()


CONFLICT = "not supported with --agent-engine=v3"


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
                           "HOME": str(home), "CFFIXED_USER_HOME": str(home),
                           "XDG_CACHE_HOME": str(root / "cache"), "XDG_CONFIG_HOME": str(root / "config"),
                           "KIRO_KAS_NODE_PATH": str(node), "KIRO_DISABLE_TELEMETRY": "1",
                           "KIRO_API_KEY": "offline-dispatch-fixture", "TERM": "dumb"}
                    args = [variant["package"] + "/bin/" + command, mode]
                    # The real factory wrapper defaults only the launcher to v3;
                    # direct-chat engine selection remains explicit.
                    if command == "kiro-cli-chat":
                        args += ["--agent-engine", "v3"]
                    if mode == "chat":
                        args += ["--no-interactive", "--model", "nix-no-such-model", "offline dispatch fixture"]
                    result = subprocess.run(args, env=env, cwd=work, input="", capture_output=True, text=True, timeout=30)
                    assert capture.exists(), (name, stale, args, result.returncode, result.stderr)
                    argv = json.loads(capture.read_text())
                    assert variant["server"] in argv, (name, stale, args, argv)
                    # KAS starting at all is the proof that the engine accepted
                    # the wrapper's argv: a `--trust-tools` conflict exits first.
                    # 3.0.0 KAS takes no trust flag (acp-server.js reads tool
                    # policy only from permissions.yaml); the grant stays with
                    # the ACP client, so it must never appear in the KAS argv.
                    if variant["trust"] is not None:
                        assert not any(variant["trust"] in token for token in argv), (name, stale, args, argv)
                    assert list(home.glob("**/kas/*/node_modules/@kiro/agent/dist/server/acp-server.js")) == ([old] if stale else []), "unexpected cache extraction"
    # Explicit inherited override remains available only in the stock variant.
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        capture, node = capture_node(root)
        override = root / "override.js"
        override.write_text("// explicit override")
        env = {"PATH": variant["package"] + "/bin:" + os.environ["PATH"], "HOME": tmp,
               "CFFIXED_USER_HOME": tmp, "KIRO_KAS_NODE_PATH": str(node),
               "KIRO_KAS_SERVER_PATH": str(override), "KIRO_API_KEY": "offline-dispatch-fixture"}
        subprocess.run([variant["package"] + "/bin/kiro-cli", "acp"], env=env, cwd=tmp,
                       input="", capture_output=True, text=True, timeout=30)
        expected = variant["server"] if variant["managed"] else str(override)
        assert expected in json.loads(capture.read_text()), (name, "override precedence")
        # An explicit v2 choice beats the injected launcher --v3. Its own
        # validation error is before auth/network and before any KAS process.
        capture.unlink()
        result = subprocess.run([variant["package"] + "/bin/kiro-cli", "acp", "--agent-engine=v2", "--auth-method", "client"],
                                env=env, cwd=tmp, input="", capture_output=True, text=True, timeout=30)
        assert result.returncode == 2 and "only supported with --agent-engine=v3" in result.stderr, result.stderr
        assert not capture.exists(), "explicit v2 started KAS"
        # Remove both overrides and initialize through native ACP with real Node.
        del env["KIRO_KAS_NODE_PATH"]
        del env["KIRO_KAS_SERVER_PATH"]
        smoke.initialize([variant["package"] + "/bin/kiro-cli", "acp"], env)
    print(f"PASS: {name}: kiro-cli/kiro-cli-chat, CLI/ACP, fresh/stale cache, explicit overrides/v2, real ACP initialize", flush=True)

# Raw measurements on the stock payload, with no managed argv injection. Each
# pins a binary behavior the trust gate in lib/wrapPackage.nix depends on.
binary = variants["stock"]["unwrapped"] + "/bin/kiro-cli"
# v3 rejects `--trust-tools` on `acp`, so the gate must withhold there.
result, _ = raw(binary, ["--v3", "acp", "--trust-tools=fs_read"])
assert result.returncode == 2 and CONFLICT in result.stderr, ("v3 acp trust", result.returncode, result.stderr)
# An explicit `--agent-engine` beats `--v3`, so the gate resolves it first.
result, _ = raw(binary, ["--v3", "acp", "--agent-engine=v2", "--auth-method", "client", "--trust-tools=fs_read"])
assert "only supported with --agent-engine=v3" in result.stderr and CONFLICT not in result.stderr, ("engine precedence", result.stderr)
# The bare launch accepts `--trust-tools` under v3 and reaches KAS.
result, started = raw(binary, ["--v3", "--trust-tools=fs_read", "--no-interactive", "--model", "nix-no-such-model", "offline dispatch fixture"])
assert started, ("bare v3 launch with trust", result.returncode, result.stderr)
# `acp` with no engine selector does not apply the v3 conflict at parse time.
result, started = raw(binary, ["acp", "--trust-tools=fs_read"])
# Parsing must accept the flag: no engine conflict and no other parse rejection.
assert CONFLICT not in result.stderr and "unexpected argument" not in result.stderr and (started or result.returncode != 2), ("unselected acp trust", result.returncode, result.stderr)
print("PASS: raw: v3 acp conflict, explicit engine precedence, bare v3 trust, unselected acp", flush=True)
