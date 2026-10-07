#!/usr/bin/env python3
"""What the nixpkgs Claude ACP adapter (claude-agent-acp, TS Agent SDK inside) sends by default.

usage: acp-adapter.py <claude-agent-acp bin> [variant...]   (acp-adapter.sh builds the adapter)

Drives the adapter as a minimal ACP client (initialize, session/new, session/prompt "hi") with
CLAUDE_CODE_EXECUTABLE = sdk-recorder.sh, which prepends a wrapper-owned
--append-system-prompt-file (APPFILE-9999) and records argv and the SDK's stream-json stdin.
Against sysprompt/mock.py with a fake key. Prints per variant:

  <variant>: init_prompt=<prompt fields in the SDK initialize> argv_prompt=<flags> tokens=<sentinels in main system>

default        session/new without _meta (adapter default: preset claude_code)
meta-append    session/new _meta.systemPrompt = {"append": "...ACPAPPEND-6262."}
meta-string    session/new _meta.systemPrompt = "...ACPSTRING-6363." (replaces the base)
"""
import json
import os
import pathlib
import queue
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = pathlib.Path(__file__).resolve().parent
SYSPROMPT = HERE.parent / "sysprompt"
TOKEN = re.compile(r"\b[A-Z]{4,}-\d{4}\b")
VARIANTS = {
    "default": None,
    "meta-append": {"systemPrompt": {"append": "ACP append sentinel: ACPAPPEND-6262."}},
    "meta-string": {"systemPrompt": "ACP string sentinel: ACPSTRING-6363."},
}
PROMPT_FIELDS = ("systemPrompt", "appendSystemPrompt", "appendSubagentSystemPrompt", "excludeDynamicSections")
PROMPT_FLAGS = ("--system-prompt", "--system-prompt-file", "--append-system-prompt", "--append-system-prompt-file")


def spawn_capture(out):
    """(argv, initialize request, env text) of the spawn whose stdin carried an initialize."""
    for stdin in sorted(out.glob("stdin-*.jsonl")):
        for line in stdin.read_text().splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("type") == "control_request" and msg.get("request", {}).get("subtype") == "initialize":
                pid = stdin.name[len("stdin-"):-len(".jsonl")]
                env = out / f"env-{pid}.txt"
                return ((out / f"argv-{pid}.txt").read_text().splitlines(), msg["request"],
                        env.read_text() if env.exists() else "")
    argv = sorted(out.glob("argv-*.txt"))
    return (argv[0].read_text().splitlines() if argv else []), {}, ""


def workdir():
    base = os.environ.get("PROBE_OUT")
    if base:
        path = pathlib.Path(base) / "claude-acp-adapter"
        path.mkdir(parents=True, exist_ok=True)
        return path
    return pathlib.Path(tempfile.mkdtemp(prefix="delegate-probe-claude-acp-adapter-"))


class Client:
    def __init__(self, argv, env, cwd):
        self.proc = subprocess.Popen(argv, env=env, cwd=cwd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=open(pathlib.Path(cwd).parent / "adapter.stderr", "w"), text=True)
        self.inbox = queue.Queue()
        self.next_id = 0
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.proc.stdout:
            try:
                self.inbox.put(json.loads(line))
            except ValueError:
                pass

    def _send(self, msg):
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()

    def call(self, method, params, timeout=120):
        self.next_id += 1
        rid = self.next_id
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                msg = self.inbox.get(timeout=1)
            except queue.Empty:
                continue
            if msg.get("id") == rid and "method" not in msg:
                return msg
            if "method" in msg and "id" in msg:  # agent -> client request: refuse politely
                self._send({"jsonrpc": "2.0", "id": msg["id"], "result": {"outcome": {"outcome": "cancelled"}}})
        raise TimeoutError(method)

    def close(self):
        self.proc.stdin.close()
        try:
            self.proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def run(adapter, work, variant):
    meta = VARIANTS[variant]
    out = work / variant
    shutil.rmtree(out, ignore_errors=True)
    (out / "reqs").mkdir(parents=True)
    cwd = out / "cwd"
    shutil.copytree(SYSPROMPT / "cwd", cwd)
    subprocess.run(["git", "-C", str(cwd), "init", "-q", "-b", "main"], check=True)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    mock = subprocess.Popen([sys.executable, "-I", str(SYSPROMPT / "mock.py")],
                            env={**os.environ, "MOCK_PORT": str(port), "MOCK_DIR": str(out / "reqs")},
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    env = {
        **{k: os.environ[k] for k in ("PATH", "CLAUDE_BIN") if k in os.environ},
        "HOME": str(out),
        "ANTHROPIC_API_KEY": "mock-offline-not-a-key",
        "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{port}",
        "ANTHROPIC_MODEL": "haiku",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        "CLAUDE_CODE_EXECUTABLE": str(HERE / "sdk-recorder.sh"),
        "CLAUDE_CONFIG_DIR": str(out / "config"),
        "DISABLE_TELEMETRY": "1",
        "RECORDER_INJECT_FILE": str(SYSPROMPT / "append.md"),
        "RECORDER_OUT": str(out),
    }
    client = Client([adapter], env, cwd)
    try:
        client.call("initialize", {"protocolVersion": 1, "clientCapabilities": {}})
        params = {"cwd": str(cwd), "mcpServers": []}
        if meta is not None:
            params["_meta"] = meta
        session = client.call("session/new", params)["result"]["sessionId"]
        client.call("session/prompt", {"sessionId": session, "prompt": [{"type": "text", "text": "hi"}]})
    finally:
        client.close()
        mock.terminate()
        mock.wait()
    argv, init, _ = spawn_capture(out)
    flags = [f"{a}={json.dumps(argv[i + 1])}" for i, a in enumerate(argv) if a in PROMPT_FLAGS]
    fields = {k: init[k] for k in PROMPT_FIELDS if init.get(k) is not None}
    system = []
    for path in sorted((out / "reqs").glob("req-*.json")):
        rec = json.loads(path.read_text())
        body = rec["body"]
        if rec["path"].startswith("/v1/messages") and "count_tokens" not in rec["path"] and body.get("tools"):
            system = body.get("system", [])
            break
    tokens = sorted({t for block in system for t in TOKEN.findall(block.get("text", ""))})
    print(f"{variant}: init_prompt={json.dumps(fields)} argv_prompt={' '.join(flags) or '-'} "
          f"sys={[len(b.get('text', '')) for b in system]} tokens={','.join(tokens) or '-'}")
    print(f"  captures: {out}")


def main():
    adapter = sys.argv[1]
    names = sys.argv[2:] or list(VARIANTS)
    work = workdir()
    for name in names:
        if name not in VARIANTS:
            sys.exit(f"unknown variant: {name}")
        run(adapter, work, name)


main()
