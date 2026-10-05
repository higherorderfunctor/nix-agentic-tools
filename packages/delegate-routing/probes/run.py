#!/usr/bin/env python3
"""Manual, opt-in CLI probes; fixtures retain metadata, never transcripts."""

# cspell:ignore strerror  (Python OSError attribute, not project vocabulary)
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import selectors
import shlex
import signal
import subprocess
import time
import uuid


RUNTIMES = {
    "claude": ("claude", [], "claude -p", ["--model", "--effort"]),
    "codex": ("codex", ["exec"], "codex exec", ["--model", "--config"]),
    "copilot": ("copilot", [], "fleet", ["--fleet", "--model", "--effort"]),
    "kimchi": ("kimchi", [], "kimchi -p", ["--model", "--thinking"]),
    "kiro": ("kiro-cli", ["chat"], "kiro-cli chat", ["--model", "--effort"]),
}
LIMIT = 131072


def capture(command, timeout):
    """Drain pipes into capped memory buffers; never persist raw streams."""
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
    except OSError:
        return None, "", "", "executable could not be started"
    buffers = [bytearray(), bytearray()]
    deadline = time.monotonic() + timeout
    status = "finished"
    truncated = False
    with selectors.DefaultSelector() as selector:
        for index, stream in enumerate((process.stdout, process.stderr)):
            selector.register(stream, selectors.EVENT_READ, index)
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                status = "timed out; process group killed"
                break
            for key, _ in selector.select(min(remaining, 0.1)):
                chunk = os.read(key.fileobj.fileno(), 8192)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                buffer = buffers[key.data]
                room = LIMIT - len(buffer)
                buffer.extend(chunk[:room])
                truncated = truncated or len(chunk) > room
    for stream in (process.stdout, process.stderr):
        stream.close()
    try:
        process.wait(timeout=max(0.1, deadline - time.monotonic()))
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
        status = "timed out; process group killed"
    if truncated:
        status += "; stream inspection truncated"
    return process.returncode, *(buffer.decode("utf-8", errors="replace") for buffer in buffers), status


def exposes(help_text, flag):
    return re.search(r"(?<![\w-])" + re.escape(flag) + r"(?![\w-])", help_text) is not None


def checked_text(value):
    if not value.strip() or len(value) > 200 or any(ord(char) < 32 for char in value):
        raise argparse.ArgumentTypeError("use a nonempty value under 201 characters without controls")
    return value


def authenticated_command(runtime, executable, model, effort, prompt):
    if runtime == "codex":
        return [executable, "exec", "--model", model, "--config", f"model_reasoning_effort={json.dumps(effort)}", prompt]
    if runtime == "kimchi":
        return [executable, "-p", "--model", model, "--thinking", effort, prompt]
    if runtime == "kiro":
        return [executable, "chat", "--no-interactive", "--model", model, "--effort", effort, prompt]
    if runtime == "copilot":
        return [executable, "--fleet", "-p", prompt, "--model", model, "--effort", effort]
    return [executable, "-p", "--model", model, "--effort", effort, prompt]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", choices=sorted(RUNTIMES), required=True)
    parser.add_argument("--output", type=Path, required=True, help="new fixture path; existing files are refused")
    parser.add_argument("--case", choices=["schema", "child", "nested", "workflow"], default="schema")
    parser.add_argument("--authenticated", action="store_true", help="explicitly permit a model turn for non-schema cases")
    parser.add_argument("--model", type=checked_text)
    parser.add_argument("--effort", type=checked_text)
    parser.add_argument("--technique", type=checked_text, help="child-case native tool to request through the external launcher")
    parser.add_argument("--timeout", type=int, default=60, help="per-command timeout in seconds (1–300)")
    args = parser.parse_args()
    if not 1 <= args.timeout <= 300:
        parser.error("--timeout must be between 1 and 300")
    if args.output.exists() or args.output.is_symlink():
        parser.error("--output must be a new file")
    if args.case != "schema" and not (args.authenticated and args.model and args.effort):
        parser.error("non-schema cases require --authenticated, --model and --effort")
    if args.technique and args.case != "child":
        parser.error("--technique is only valid for --case child")

    executable, subcommand, launcher, flags = RUNTIMES[args.runtime]
    replay = []
    cwd = os.getcwd()

    def run(command):
        replay.append(f"cd {shlex.quote(cwd)} && {shlex.join(command)}")
        return capture(command, args.timeout)

    version_code, version_stdout, version_stderr, version_status = run([executable, "--version"])
    version_match = re.search(r"\b\d+\.\d+\.\d+(?:[-+][\w.-]+)?\b", version_stdout + version_stderr)
    version = version_match.group(0) if version_code == 0 and version_match else None
    help_code, help_stdout, help_stderr, help_status = run([executable, "--help"])
    if subcommand:
        help_code, help_stdout, help_stderr, help_status = run([executable, *subcommand, "--help"])
    help_text = help_stdout + help_stderr
    required = list(flags)
    if args.runtime in ("claude", "copilot", "kimchi"):
        required.append("-p")
    if args.runtime == "kiro":
        required.append("--no-interactive")
    exposed = [flag for flag in required if exposes(help_text, flag)]
    schema_available = help_code == 0 and help_status == "finished" and len(exposed) == len(required)
    evidence = (
        f"Version exit={version_code}, {version_status}; launcher help exit={help_code}, {help_status}; "
        f"exact flags exposed={','.join(exposed) or 'none'}. Help establishes syntax only; native tool availability unknown."
    )
    result = "unknown"
    technique = args.technique or launcher
    context = f"Manual {args.case} probe from {cwd}; no trust or permission bypass flags."
    if args.case != "schema":
        nonce = "delegate-probe-" + uuid.uuid4().hex
        request = {
            "child": (
                f"Invoke exactly one child using {args.technique or 'a native subagent tool'} "
                "to return the nonce prefix; then send that same child one bounded native follow-up "
                "request to return the full nonce"
            ),
            "nested": "Invoke a native child and ask that child to invoke one native grandchild (depth two)",
            "workflow": (
                "Invoke a native workflow containing a producer node that returns the nonce prefix "
                "and one dependent child node that uses that prefix to return the full nonce"
            ),
        }[args.case]
        prompt = (
            f"Manual capability probe. {request}, requesting model {args.model!r} and effort {args.effort!r} "
            f"for every delegate. Ask the final delegate to return {nonce}. "
            "Do not modify files, run shell commands, commit, or access account data. "
            "If the requested native tool is unavailable, say unavailable. "
            "Do not substitute prose or simulated execution for a tool call."
        )
        if schema_available:
            code, stdout, stderr, status = run(authenticated_command(args.runtime, executable, args.model, args.effort, prompt))
            evidence += (
                f" Authenticated launcher exit={code}, {status}; nonce present in bounded "
                f"stdout={nonce in stdout}, stderr={nonce in stderr}. "
                "Exit status and nonce do not establish child completion, effective pins, or nested tool execution."
            )
            if not args.technique:
                result = "supported" if code == 0 and status == "finished" and nonce in stdout else "unknown"
        else:
            evidence += " Authenticated turn skipped: complete successful help did not expose every required launcher flag."
        context += " Operator must inspect authoritative machine tool events before promoting any native claim."

    unknown = "Unknown: no authoritative machine tool events inspected; self-report and nonce are insufficient."
    capabilities = {
        "available": {"result": result, "evidence": evidence},
        "linkedWorktreeCommit": {"result": "unknown", "evidence": "Not exercised: this probe forbids file modifications and commits."},
        "nestingDepth": {"result": "unknown", "evidence": unknown, "value": None},
        "pinsEffort": {"result": "unknown", "evidence": unknown},
        "pinsModel": {"result": "unknown", "evidence": unknown},
        "runsOwnSubagents": {"result": "unknown", "evidence": unknown},
    }
    fixture = {
        "capabilities": capabilities,
        "context": context,
        "date": datetime.date.today().isoformat(),
        "mode": "headless",
        "observed": {"effort": None, "model": None},
        "replay": replay,
        "requested": {"effort": args.effort, "model": args.model},
        "runtime": args.runtime,
        "runtimeVersion": version,
        "source": "Manual opt-in runner; only return codes, exact help flag exposure and bounded nonce presence retained; raw streams discarded.",
        "technique": technique,
    }
    try:
        with args.output.open("x", encoding="utf-8") as output:
            json.dump(fixture, output, indent=2, sort_keys=True)
            output.write("\n")
    except OSError as error:
        parser.error(f"cannot create new output fixture: {error.strerror}")
    print(f"Wrote {args.output}; effective pins and native execution remain unknown.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
