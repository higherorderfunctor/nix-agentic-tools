#!/usr/bin/env python3
"""Does the hidden sub-agent append reach children spawned from the INTERACTIVE TUI?

usage: tui-subagent.py <variant>...   variants: inline, inline-env, file, env-only, none, guide

Runs the pinned claude in tmux (no -p) against the loopback mock with a fake key.
The first prompt "SPAWN" makes the mock call Agent (plan-gp.json: general-purpose,
named-agent, Explore). Prints one line per variant:

  <variant>: main_append=<bool> children=<n> child_subapp=<n>/<n> main_subapp=<bool>

inline   --append-subagent-system-prompt "...SUBAPP-1414."
inline-env  the same flag plus CLAUDE_CODE_ENABLE_APPEND_SUBAGENT_PROMPT=1
file     --append-subagent-system-prompt-file <file with SUBFILE-1515>
env-only CLAUDE_CODE_ENABLE_APPEND_SUBAGENT_PROMPT=1, no flag (control: nothing to append)
none     neither flag nor env (control)
guide    inline flag; spawns the TUI-only built-in claude-code-guide (plan-guide.json)
team     agent teams on; Agent with team_name (plan-gated.json "TEAM"); token = MAIN append
"""
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
binary = os.environ.get("CLAUDE_BIN") or str(pin.package("claude-code") / "bin" / "claude")
work = pin.workdir("claude-tui-subagent")
SUBFILE = "Subagent file append: SUBFILE-1515."
INLINE = ["--append-subagent-system-prompt", "Subagent append: SUBAPP-1414."]
GATE = {"CLAUDE_CODE_ENABLE_APPEND_SUBAGENT_PROMPT": "1"}
# variant -> (extra argv, extra env, token expected in child system, mock plan)
VARIANTS = {
    "inline": (INLINE, {}, "SUBAPP-1414", "plan-gp.json"),
    "inline-env": (INLINE, GATE, "SUBAPP-1414", "plan-gp.json"),
    "file": (["--append-subagent-system-prompt-file", "@SUBFILE@"], {}, "SUBFILE-1515", "plan-gp.json"),
    "env-only": ([], GATE, "SUBAPP-1414", "plan-gp.json"),
    "none": ([], {}, "SUBAPP-1414", "plan-gp.json"),
    "guide": (INLINE, {}, "SUBAPP-1414", "plan-guide.json"),
    "team": (INLINE, {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"}, "APPINLINE-1313", "plan-gated.json"),
}


def run(variant):
    flags, extra_env, token, plan = VARIANTS[variant]
    out = work / variant
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    cfg = out / "config"
    cfg.mkdir()
    cwd = out / "cwd"
    shutil.copytree(here / "cwd", cwd)
    subprocess.run(["git", "-C", str(cwd), "init", "-q", "-b", "main"], check=True)
    subfile = out / "subappend.md"
    subfile.write_text(SUBFILE + "\n")
    flags = [str(subfile) if f == "@SUBFILE@" else f for f in flags]
    (cfg / ".claude.json").write_text(json.dumps({
        "hasCompletedOnboarding": True,
        "projects": {str(cwd): {"hasCompletedProjectOnboarding": True, "hasTrustDialogAccepted": True}},
        "theme": "dark",
    }))
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    reqs = out / "reqs"
    env = {key: os.environ[key] for key in ("PATH", "TERM") if key in os.environ}
    env.update({
        "ANTHROPIC_API_KEY": "mock-offline-not-a-key",
        "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{port}",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        "CLAUDE_CONFIG_DIR": str(cfg),
        "DISABLE_AUTOUPDATER": "1",
        "HOME": str(out),
        "MOCK_DIR": str(reqs),
        "MOCK_PLAN": str(here / plan),
        "MOCK_PORT": str(port),
        **extra_env,
    })
    argv = [binary, "--model", "haiku", "--setting-sources", "project", "--strict-mcp-config",
            "--mcp-config", '{"mcpServers":{}}', "--allowedTools", "Agent",
            "--append-system-prompt", "Inline append sentinel: APPINLINE-1313.", *flags,
            "TEAM" if plan == "plan-gated.json" else "SPAWN"]
    (out / "argv.json").write_text(json.dumps({"argv": argv, "cwd": str(cwd), "env": sorted(extra_env)}))
    server = subprocess.Popen(["python3", str(here / "mock.py")], env=env,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    tmux = ["tmux", "-L", f"claude-probe-{uuid.uuid4().hex}"]

    def pane():
        return subprocess.check_output(tmux + ["capture-pane", "-p", "-t", "probe"], text=True)

    def send(*keys):
        subprocess.run(tmux + ["send-keys", "-t", "probe", *keys], check=True)

    def bodies():
        found = []
        for path in sorted(reqs.glob("req-*.json")):
            rec = json.loads(path.read_text())
            if "count_tokens" in rec["path"] or not rec["path"].startswith("/v1/messages"):
                continue
            found.append(rec["body"])
        return found

    try:
        subprocess.run(tmux + ["new-session", "-d", "-s", "probe", "-c", str(cwd), "-x", "120", "-y", "40",
                              shlex.join(argv)], check=True, env=env)
        for _ in range(120):
            time.sleep(0.5)
            screen = pane()
            (out / "pane.txt").write_text(screen)
            if "Do you want to use this API key?" in screen:
                send("Up", "Enter")
            elif "trust" in screen.lower() or "safety check" in screen.lower():
                send("Enter")
            # main request, three children, main follow-up after the tool results
            mains = [b for b in bodies() if "cc_is_subagent" not in json.dumps(b.get("system"))
                     and "Subtask" not in json.dumps(b.get("messages", [])[:1])]
            if len(mains) >= 2 and any("Subtask" in json.dumps(b.get("messages")) for b in bodies() if b not in mains):
                break
        else:
            raise RuntimeError(f"{variant}: TUI did not finish the spawn round; see {out / 'pane.txt'}")
    finally:
        subprocess.run(tmux + ["kill-server"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        server.terminate()
        server.wait()
    all_bodies = bodies()
    mains = [b for b in all_bodies if "cc_is_subagent" not in json.dumps(b.get("system"))
             and "Subtask" not in json.dumps(b.get("messages", [])[:1])]
    children = [b for b in all_bodies if b not in mains and "Subtask" in json.dumps(b.get("messages"))]
    hit = sum(token in json.dumps(b.get("system")) for b in children)
    main_sub = any(token in json.dumps(b.get("system")) for b in mains)
    main_append = bool(mains) and all("APPINLINE-1313" in json.dumps(b.get("system")) for b in mains)
    print(f"{variant}: main_append={main_append} children={len(children)} child_subapp={hit}/{len(children)} "
          f"main_subapp={main_sub} token={token}")
    print(f"  captures: {reqs}")


if __name__ == "__main__":
    names = sys.argv[1:] or list(VARIANTS)
    for name in names:
        if name not in VARIANTS:
            sys.exit(f"unknown variant: {name}")
        run(name)
