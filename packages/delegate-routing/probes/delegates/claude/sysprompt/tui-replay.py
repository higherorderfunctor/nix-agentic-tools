#!/usr/bin/env python3
"""Capture interactive and /compact prompts against the loopback mock, with a fake key."""
import json
import os
from pathlib import Path
import shlex
import shutil
import socket
import subprocess
import sys
import time
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "common"))
import pin  # noqa: E402

here = Path(__file__).resolve().parent
work = pin.workdir("claude-tui")
out = work / "out"
shutil.rmtree(out, ignore_errors=True)
out.mkdir(parents=True)
cfg = work / "config"
cfg.mkdir(exist_ok=True)
cwd = work / "cwd"
if not cwd.exists():
    shutil.copytree(here / "cwd", cwd)
    subprocess.run(["git", "-C", str(cwd), "init", "-q", "-b", "main"], check=True)
(cfg / ".claude.json").write_text(json.dumps({
    "hasCompletedOnboarding": True,
    "projects": {str(cwd): {"hasCompletedProjectOnboarding": True, "hasTrustDialogAccepted": True}},
    "theme": "dark",
}))
with socket.socket() as listener:
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
env = {key: os.environ[key] for key in ("PATH", "TERM") if key in os.environ}
env.update({
    "ANTHROPIC_API_KEY": "mock-offline-not-a-key",
    "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{port}",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
    "CLAUDE_CONFIG_DIR": str(cfg),
    "DISABLE_AUTOUPDATER": "1",
    "HOME": str(work),
    "MOCK_DIR": str(out),
    "MOCK_PORT": str(port),
})
binary = os.environ.get("CLAUDE_BIN") or str(pin.package("claude-code") / "bin" / "claude")
argv = [binary, "--model", "haiku", "--setting-sources", "project", "--strict-mcp-config",
        "--mcp-config", '{"mcpServers":{}}', "--append-system-prompt", "Inline append sentinel: APPINLINE-1313.", "hello"]
(out / "argv.json").write_text(json.dumps({"argv": argv, "cwd": str(cwd)}))
server = subprocess.Popen(["python3", str(here / "mock.py")], env=env,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
tmux = ["tmux", "-L", f"claude-probe-{uuid.uuid4().hex}"]

def pane():
    return subprocess.check_output(tmux + ["capture-pane", "-p", "-t", "probe"], text=True)

def send(*keys):
    subprocess.run(tmux + ["send-keys", "-t", "probe", *keys], check=True)

def captures():
    return [(path, json.loads(path.read_text())["body"]) for path in sorted(out.glob("req-*.json"))
            if "count_tokens" not in json.loads(path.read_text())["path"]]

try:
    subprocess.run(tmux + ["new-session", "-d", "-s", "probe", "-c", str(cwd), "-x", "100", "-y", "40",
                          shlex.join(argv)], check=True, env=env)
    for _ in range(60):
        time.sleep(0.5)
        screen = pane()
        (out / "pane.txt").write_text(screen)
        if "Do you want to use this API key?" in screen:
            send("Up", "Enter")
        elif "trust" in screen.lower() or "safety check" in screen.lower():
            send("Enter")
        if captures() and "ok-" in screen:
            break
    else:
        raise RuntimeError(f"TUI setup did not reach the fake API; inspect {out / 'pane.txt'}")
    main = captures()[0][1]
    assert "APPINLINE-1313" in json.dumps(main["system"]), "main append missing"
    send("/compact", "Enter")
    for _ in range(60):
        time.sleep(0.5)
        compact = [(path, body) for path, body in captures()
                   if "<summary>" in json.dumps(body.get("messages"))]
        if compact:
            break
    else:
        raise AssertionError("/compact did not issue a summarizer request")
    assert compact[0][1]["system"] == main["system"], "compaction did not copy the parent system"
    print(f"K1 append present; body chars={len(main['system'][2]['text'])}; K8 compaction copies parent system")
    print(f"captures: {out}")
finally:
    subprocess.run(tmux + ["kill-server"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    server.terminate()
    server.wait()
