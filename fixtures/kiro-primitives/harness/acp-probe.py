#!/usr/bin/env python3
"""Drive the engine's UNADVERTISED workflow extension methods directly over ACP.

WHY THIS EXISTS: the shipped TUI cannot start a workflow deterministically. The
four /workflow-* slash commands are inert, and the one command wired end to end
is gated on a different setting. That leaves a tool call the model must choose to
make -- which is a poor foundation for a fixture.

This bypasses all of it. The engine registers 20 `_kiro/workflow/*` ACP
extension methods UNCONDITIONALLY and does not list them in the handshake's
advertised extensionMethods, so they are implemented-but-unadvertised and must be
called by name. Confirmed reachable with NO seeded session, NO workflow flag, and
NO model in the loop.

TWO THINGS THAT WILL BITE YOU:

1. The wrapped `kiro-cli` on this machine appends `--tui --v3` unconditionally,
   and the `acp` subcommand REJECTS both -- so ACP mode is unreachable through
   the wrapper and the process dies with "unexpected argument '--tui'". This
   resolves the real binary out of the wrapper's exec line instead.

2. The agent sends REQUESTS to the client (notably `_kiro/auth/getAccessToken`)
   interleaved with responses. A naive send/read/send/read pairs the wrong
   messages together and reads an initialize result as though it answered a later
   call. Hence the id-matching loop.

This client answers the token request with an ERROR rather than reading the
operator's credential store. Everything reachable without a token is therefore
in scope here; anything needing a model call is not, and stays operator-driven.

Framing is newline-delimited JSON-RPC (the ACP SDK splits on newlines), NOT
Content-Length.

Usage:
  acp-probe.py <scratch-home> <workspace> <definition.workflow.json>

Validates a definition through `_kiro/workflow/new`, which performs FULL
validation INCLUDING agent resolution -- something the `validate_workflow` tool
never does. Writes only under the scratch home.
"""

import json
import os
import shutil
import subprocess
import sys
import threading
import queue
import time

# Checked rather than indexed blind: this is operator-facing, and the failure
# for a mistyped invocation should be the usage line -- not an IndexError
# traceback pointing at line 51, which says nothing about what was expected.
# `acp-host.py` already guards its own argv this way; this file was the outlier.
if len(sys.argv) < 4:
    raise SystemExit(
        "usage: acp-probe.py <scratch-home> <workspace> <definition.workflow.json>"
    )

SCRATCH = sys.argv[1]
WORKSPACE = sys.argv[2]
DEFINITION_PATH = sys.argv[3]

_found = shutil.which("kiro-cli")
if _found is None:
    raise SystemExit("kiro-cli is not on PATH — this probe drives the real CLI")
launcher = os.path.realpath(_found)
KIRO = launcher
# Read the wrapper as text only if it IS text. A compiled binary raises
# UnicodeDecodeError here, and that is the normal case on a machine without the
# wrapper -- it means the launcher already IS the real binary, so keep it.
try:
    with open(launcher, encoding="utf-8") as fh:
        head = fh.read(4096)
except (OSError, UnicodeDecodeError):
    head = ""
if head.startswith("#!"):
    # A shebang means this IS a wrapper, so failing to extract the real binary
    # from it must be LOUD. Leaving KIRO pointed at the wrapper would invoke the
    # exact thing this file exists to bypass, and the symptom -- the launcher
    # rejecting `acp` because it appended `--tui` -- reads as an engine problem
    # rather than as a resolution one.
    #
    # Tokens are unquoted before matching. This launcher writes the store path
    # bare (`exec -a "$0" /nix/store/.../bin/kiro-cli "$@"`), but a generator
    # change to a shell-escaped form is one `escapeShellArg` away, and then
    # `endswith` silently stops matching.
    resolved = None
    for line in head.splitlines():
        if line.startswith("exec ") and "/bin/kiro-cli" in line:
            for tok in line.split():
                tok = tok.strip("'\"")
                if tok.endswith("/bin/kiro-cli"):
                    resolved = tok
    if resolved is None:
        raise SystemExit(f"could not resolve the unwrapped kiro-cli from {launcher}")
    KIRO = resolved

env = dict(os.environ)
env["HOME"] = SCRATCH
env["KIRO_LOG_LEVEL"] = "debug"

proc = subprocess.Popen(
    [KIRO, "acp", "--agent-engine", "v3"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    env=env, text=True, bufsize=1,
)

inbox: "queue.Queue" = queue.Queue()
err_lines = []


def pump_out(stream):
    for line in stream:
        if line.strip():
            inbox.put(line.rstrip("\n"))
    inbox.put(None)


def pump_err(stream):
    for line in stream:
        err_lines.append(line.rstrip("\n"))


threading.Thread(target=pump_out, args=(proc.stdout,), daemon=True).start()
threading.Thread(target=pump_err, args=(proc.stderr,), daemon=True).start()


def send(obj):
    try:
        proc.stdin.write(json.dumps(obj) + "\n")
        proc.stdin.flush()
        return True
    except (BrokenPipeError, ValueError):
        return False


def await_id(target_id, timeout=45):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            line = inbox.get(timeout=max(0.5, deadline - time.time()))
        except queue.Empty:
            break
        if line is None:
            return {"__eof__": True, "exit": proc.poll()}
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        if "method" in msg and "id" in msg:
            send({"jsonrpc": "2.0", "id": msg["id"],
                  "error": {"code": -32601, "message": "probe client supplies no tokens"}})
            continue
        if "method" in msg:
            continue
        if msg.get("id") == target_id:
            return msg
    return {"__timeout__": True, "exit": proc.poll()}


with open(DEFINITION_PATH) as fh:
    definition = json.load(fh)

out = {}

send({"jsonrpc": "2.0", "id": 1, "method": "initialize",
      "params": {"protocolVersion": 1,
                 "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}}}})
out["initialize_ok"] = "result" in await_id(1)

# list, now with the parameter it complained about
send({"jsonrpc": "2.0", "id": 2, "method": "_kiro/workflow/list",
      "params": {"workspacePaths": [WORKSPACE]}})
out["list"] = await_id(2)

# THE validation: full, including agent resolution. No parentSessionId, so the
# registry is built from the workspace roots.
send({"jsonrpc": "2.0", "id": 3, "method": "_kiro/workflow/new",
      "params": {"workspacePaths": [WORKSPACE], "workflow": definition}})
new_res = await_id(3, timeout=90)
out["new"] = new_res

run_id = None
if isinstance(new_res, dict) and "result" in new_res:
    r = new_res["result"]
    run_id = r.get("runId") or r.get("id") or (r.get("run") or {}).get("id")
    out["run_id_field"] = run_id

if run_id:
    send({"jsonrpc": "2.0", "id": 4, "method": "_kiro/workflow/inspect",
          "params": {"runId": run_id}})
    out["inspect"] = await_id(4)
    send({"jsonrpc": "2.0", "id": 5, "method": "_kiro/workflow/delete",
          "params": {"runId": run_id}})
    out["delete"] = await_id(5)

try:
    proc.stdin.close()
except Exception:
    pass
try:
    proc.wait(timeout=8)
except subprocess.TimeoutExpired:
    proc.kill()

print(json.dumps({"results": out, "stderr_tail": err_lines[-8:]}, indent=2, default=str))
