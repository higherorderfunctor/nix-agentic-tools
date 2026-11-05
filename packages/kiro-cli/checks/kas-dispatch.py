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


def raw(binary, arguments, stdin="", env=None):
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
        run_env.update(TMPDIR=str(scratch), KIRO_LOG_LEVEL="info", **(env or {}))
        result = subprocess.run([binary, *arguments], env=run_env, cwd=work,
                                input=stdin, capture_output=True, text=True, timeout=30)
        log = [line for path in scratch.glob("kiro-log/*.log")
               for line in path.read_text(errors="replace").splitlines()
               if "acp engine" in line or "ACP initialize" in line or "agentEngine" in line]
        return {"returncode": result.returncode, "started": capture.exists(),
                "stdout": result.stdout, "stderr": result.stderr, "log": log}


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
        # The wrapper names the engine on `acp` itself: a client on the v2
        # client list still reaches KAS, which neither `--v3` nor upstream's
        # default would give it.
        capture.unlink()
        subprocess.run([variant["package"] + "/bin/kiro-cli", "acp"], env=env, cwd=tmp,
                       input=smoke.request("acp-smoke"), capture_output=True, text=True, timeout=30)
        assert capture.exists(), (name, "v2-listed client through the wrapper")
        # An explicit v2 choice beats the injected engine. Its own
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
    print(f"PASS: {name}: kiro-cli/kiro-cli-chat, CLI/ACP, fresh/stale cache, explicit overrides/v2, v2-listed client, real ACP initialize", flush=True)

# Raw measurements on the stock payload, with no managed argv injection. The
# whole matrix prints before any assertion, so one CI run records every row.
# Each assertion pins a binary behavior the wrapper in lib/wrapPackage.nix
# depends on: the `acp` engine selector it appends and the trust gate behind it.
binary = variants["stock"]["unwrapped"] + "/bin/kiro-cli"
TRUST = "--trust-tools=fs_read"
INPUTS = {"eof": "", "nix-check": smoke.request(), "acp-smoke": smoke.request("acp-smoke")}
CASES = [({}, argv) for argv in (
    ["--v3", "acp"], ["acp"], ["acp", "--agent-engine=v3"],
    ["--v3", "acp", TRUST], ["acp", "--agent-engine=v3", TRUST], ["acp", TRUST],
)] + [({"KIRO_AGENT_ENGINE": "v3"}, ["acp"])]
measured = {}
for env, argv in CASES:
    for kind, stdin in INPUTS.items():
        row = measured[(tuple(env.items()), tuple(argv), kind)] = raw(binary, argv, stdin, env)
        print("MEASURE", json.dumps({"env": env, "argv": argv, "stdin": kind,
                                      "returncode": row["returncode"], "started": row["started"],
                                      "stdout": row["stdout"][:200], "stderr": row["stderr"][:200],
                                      "log": row["log"][-3:]}), flush=True)


def at(argv, kind, env=()):
    return measured[(env, tuple(argv), kind)]


# The wrapper's acp selector: an explicit `--agent-engine=v3` starts KAS for
# every client, one on the built-in v2 list included, with or without an initialize.
for kind in INPUTS:
    assert at(["acp", "--agent-engine=v3"], kind)["started"], ("explicit v3 acp", kind, at(["acp", "--agent-engine=v3"], kind))
# It rejects `--trust-tools` before KAS starts, so the trust gate withholds there.
for kind in INPUTS:
    row = at(["acp", "--agent-engine=v3", TRUST], kind)
    assert row["returncode"] == 2 and CONFLICT in row["stderr"] and not row["started"], ("explicit v3 acp trust", kind, row)
# With no selector `--trust-tools` parses on `acp`, so the gate's append is safe.
row = at(["acp", TRUST], "nix-check")
assert CONFLICT not in row["stderr"] and "unexpected argument" not in row["stderr"], ("unselected acp trust", row)
# An explicit `--agent-engine` beats `--v3`, so the gate resolves it first.
row = raw(binary, ["--v3", "acp", "--agent-engine=v2", "--auth-method", "client", TRUST])
assert "only supported with --agent-engine=v3" in row["stderr"] and CONFLICT not in row["stderr"], ("engine precedence", row)
# The bare launch accepts `--trust-tools` under v3 and reaches KAS.
row = raw(binary, ["--v3", TRUST, "--no-interactive", "--model", "nix-no-such-model", "offline dispatch fixture"])
assert row["started"], ("bare v3 launch with trust", row)
print("PASS: raw: explicit v3 acp for every client, explicit v3 acp trust conflict, unselected acp trust, explicit engine precedence, bare v3 trust", flush=True)
