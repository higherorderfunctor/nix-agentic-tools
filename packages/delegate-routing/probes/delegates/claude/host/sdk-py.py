"""What the official Python Agent SDK sends to the CLI by default (run via sdk-py.sh).

Each variant runs one `query("hi")` through claude_agent_sdk with cli_path = sdk-recorder.sh,
against sysprompt/mock.py with a fake key, and prints one line:

  <variant>: sdk=<ver> argv_prompt=<prompt flags> init_keys=<initialize keys> sys=<lens> tokens=<sentinels> identity=<sys[1] head>

default         ClaudeAgentOptions() with no system_prompt
preset          system_prompt={"type":"preset","preset":"claude_code"}
preset-append   the preset plus append "SDKAPPEND-6161"
default-inject  default, and the cli_path wrapper prepends --append-system-prompt-file (APPFILE-9999)
preset-inject   preset-append, plus the same wrapper-injected file
"""
import asyncio
import json
import os
import pathlib
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

import claude_agent_sdk as sdk
from claude_agent_sdk import ClaudeAgentOptions, query

HERE = pathlib.Path(__file__).resolve().parent
SYSPROMPT = HERE.parent / "sysprompt"
TOKEN = re.compile(r"\b[A-Z]{4,}-\d{4}\b")
PRESET = {"type": "preset", "preset": "claude_code"}
VARIANTS = {
    "default": ({}, False),
    "preset": ({"system_prompt": PRESET}, False),
    "preset-append": ({"system_prompt": {**PRESET, "append": "SDK append sentinel: SDKAPPEND-6161."}}, False),
    "default-inject": ({}, True),
    "preset-inject": ({"system_prompt": {**PRESET, "append": "SDK append sentinel: SDKAPPEND-6161."}}, True),
}
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
        path = pathlib.Path(base) / "claude-sdk-py"
        path.mkdir(parents=True, exist_ok=True)
        return path
    return pathlib.Path(tempfile.mkdtemp(prefix="delegate-probe-claude-sdk-py-"))


async def drive(options):
    async for _ in query(prompt="hi", options=options):
        pass


def run(work, variant):
    extra, inject = VARIANTS[variant]
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
        "ANTHROPIC_API_KEY": "mock-offline-not-a-key",
        "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{port}",
        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
        "CLAUDE_CONFIG_DIR": str(out / "config"),
        "DISABLE_TELEMETRY": "1",
        "RECORDER_OUT": str(out),
    }
    if inject:
        env["RECORDER_INJECT_FILE"] = str(SYSPROMPT / "append.md")
    try:
        for _ in range(50):
            try:
                socket.create_connection(("127.0.0.1", port), timeout=0.2).close()
                break
            except OSError:
                time.sleep(0.1)
        options = ClaudeAgentOptions(cli_path=str(HERE / "sdk-recorder.sh"), cwd=str(cwd), env=env,
                                     model="haiku", **extra)
        asyncio.run(drive(options))
    finally:
        mock.terminate()
        mock.wait()
    argv, init, env_text = spawn_capture(out)
    flags = [f"{a}={json.dumps(argv[i + 1])}" for i, a in enumerate(argv) if a in PROMPT_FLAGS]
    body = None
    for path in sorted((out / "reqs").glob("req-*.json")):
        rec = json.loads(path.read_text())
        if rec["path"].startswith("/v1/messages") and "count_tokens" not in rec["path"]:
            body = rec["body"]
            break
    system = body.get("system", []) if body else []
    tokens = sorted({t for block in system for t in TOKEN.findall(block.get("text", ""))})
    print(f"{variant}: sdk={sdk.__version__} argv_prompt={' '.join(flags) or '-'} "
          f"init_keys={','.join(sorted(k for k, v in init.items() if v is not None))} "
          f"sys={[len(b.get('text', '')) for b in system]} tokens={','.join(tokens) or '-'} "
          f"identity={json.dumps(system[1]['text'][:60]) if len(system) > 1 else '-'}")
    print(f"  {env_text.strip().replace(chr(10), ' ')}; captures: {out}")


def main():
    work = workdir()
    names = sys.argv[1:] or list(VARIANTS)
    for name in names:
        if name not in VARIANTS:
            sys.exit(f"unknown variant: {name}")
        run(work, name)


main()
