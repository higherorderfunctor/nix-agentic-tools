"""Real native dispatch through the wrapper: package binding beats old caches.

The wrapper's `acp --agent-engine=v3` reaches KAS for a client on the binary's
built-in v2 list, and the stock variant's raw measurement pins the binary
behavior that selector is built on.
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


def raw(binary, arguments, stdin=""):
    """Run the stock binary with no managed argv injection and report what it did.

    `started`: the capture node ran, so the acp relay spawned KAS (it resolves
    node from KIRO_KAS_NODE_PATH). `stdout`: non-empty when the v2 engine
    answered the initialize itself. `log`: the binary's acp-engine lines from
    $TMPDIR/kiro-log/kiro-chat.log at KIRO_LOG_LEVEL=info.
    """
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        capture, node = capture_node(root)
        work, scratch = root / "work", root / "tmp"
        work.mkdir()
        scratch.mkdir()
        run_env = offline_env(root, str(Path(binary).parent), node)
        run_env.update(TMPDIR=str(scratch), KIRO_LOG_LEVEL="info")
        result = subprocess.run([binary, *arguments], env=run_env, cwd=work,
                                input=stdin, capture_output=True, text=True, timeout=30)
        log = [line for path in scratch.glob("kiro-log/*.log")
               for line in path.read_text(errors="replace").splitlines()
               if "acp engine" in line or "ACP initialize" in line or "agentEngine" in line]
        return {"returncode": result.returncode, "started": capture.exists(),
                "stdout": result.stdout, "stderr": result.stderr, "log": log}


for name, variant in variants.items():
    for stale in (False, True):
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
                args = [variant["package"] + "/bin/kiro-cli", mode]
                if mode == "chat":
                    args += ["--no-interactive", "--model", "nix-no-such-model", "offline dispatch fixture"]
                result = subprocess.run(args, env=env, cwd=work, input="", capture_output=True, text=True, timeout=30)
                assert capture.exists(), (name, stale, args, result.returncode, result.stderr)
                argv = json.loads(capture.read_text())
                assert variant["server"] in argv, (name, stale, args, argv)
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
        # The wrapper names the engine on `acp` itself: `acp-smoke` is on the
        # binary's v2 client list, so without the appended selector upstream's
        # default would answer it with the v2 engine and never start KAS.
        capture.unlink()
        subprocess.run([variant["package"] + "/bin/kiro-cli", "acp"], env=env, cwd=tmp,
                       input=smoke.request("acp-smoke"), capture_output=True, text=True, timeout=30)
        assert capture.exists(), (name, "v2-listed client through the wrapper")
        # Remove both overrides and initialize through native ACP with real Node.
        del env["KIRO_KAS_NODE_PATH"]
        del env["KIRO_KAS_SERVER_PATH"]
        smoke.initialize([variant["package"] + "/bin/kiro-cli", "acp"], env)
    print(f"PASS: {name}: CLI/ACP, fresh/stale cache, explicit override, v2-listed client, real ACP initialize", flush=True)

# Raw measurement on the stock payload, with no managed argv injection: the
# binary fact the wrapper's `acp` selector depends on. An explicit
# `--agent-engine=v3` starts KAS for every client, one on the built-in v2 list
# included, with or without an initialize. Every row prints before the
# assertion, so one CI run records the whole matrix.
binary = variants["stock"]["unwrapped"] + "/bin/kiro-cli"
INPUTS = {"eof": "", "nix-check": smoke.request(), "acp-smoke": smoke.request("acp-smoke")}
measured = {}
for kind, stdin in INPUTS.items():
    row = measured[kind] = raw(binary, ["acp", "--agent-engine=v3"], stdin)
    print("MEASURE", json.dumps({"argv": ["acp", "--agent-engine=v3"], "stdin": kind,
                                  "returncode": row["returncode"], "started": row["started"],
                                  "stdout": row["stdout"][:200], "stderr": row["stderr"][:200],
                                  "log": row["log"][-3:]}), flush=True)
for kind, row in measured.items():
    assert row["started"], ("explicit v3 acp", kind, row)
print("PASS: raw: explicit v3 acp starts KAS for every client", flush=True)
