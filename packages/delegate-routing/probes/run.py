#!/usr/bin/env python3
"""Manual, opt-in CLI probes with operator-held authenticated event streams."""

# cspell:ignore strerror  (Python OSError attribute, not project vocabulary)
import argparse
from contextlib import ExitStack
import datetime
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import tempfile
import uuid


# Material flags mirror lib/techniques.nix and must change together.
LAUNCHERS = {
    "claude": ("claude -p", ["claude", "-p", "--model", "{model}", "--effort", "{effort}", "{prompt}"]),
    "codex": ("codex exec", ["codex", "exec", "--model", "{model}", "--config", "model_reasoning_effort={effort_json}", "--json", "{prompt}"]),
    "copilot": ("fleet", ["copilot", "--fleet", "-p", "{prompt}", "--model", "{model}", "--effort", "{effort}"]),
    "kimchi": ("kimchi -p", ["kimchi", "-p", "--mode", "json", "--no-session", "--model", "{model}", "--thinking", "{effort}", "{prompt}"]),
    "kiro": ("kiro-cli chat", ["kiro-cli", "chat", "--no-interactive", "--model", "{model}", "--effort", "{effort}", "{prompt}"]),
}


def capture(command, timeout, event_paths=None):
    """Retain authenticated streams; use temporary files for version/help."""
    with ExitStack() as stack:
        streams = [
            stack.enter_context(path.open("x+b") if path else tempfile.TemporaryFile())
            for path in (event_paths or (None, None))
        ]
        try:
            process = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=streams[0],
                stderr=streams[1],
                start_new_session=True,
            )
        except OSError:
            return None, "", "", "executable could not be started"
        status = "finished"
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            status = "timed out; process group killed"
        for stream in streams:
            stream.seek(0)
        return process.returncode, *(stream.read().decode("utf-8", errors="replace") for stream in streams), status


def exposes(help_text, flag):
    return re.search(r"(?<![\w-])" + re.escape(flag) + r"(?![\w-])", help_text) is not None


def checked_text(value):
    if not value.strip() or len(value) > 200 or any(ord(char) < 32 for char in value):
        raise argparse.ArgumentTypeError("use a nonempty value under 201 characters without controls")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", choices=sorted(LAUNCHERS), required=True)
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

    launcher, template = LAUNCHERS[args.runtime]
    executable = template[0]
    first_flag = next(index for index, token in enumerate(template) if token.startswith("-"))
    help_command = template[:first_flag] + ["--help"]
    required = [token for token in template if token.startswith("-")]
    replay = []

    def run(command, event_paths=None):
        replay.append(shlex.join(command))
        return capture(command, args.timeout, event_paths)

    version_code, version_stdout, version_stderr, version_status = run([executable, "--version"])
    version_match = re.search(r"\b\d+\.\d+\.\d+(?:[-+][\w.-]+)?\b", version_stdout + version_stderr)
    version = version_match.group(0) if version_code == 0 and version_match else None
    help_code, help_stdout, help_stderr, help_status = run([executable, "--help"])
    if help_command != [executable, "--help"]:
        help_code, help_stdout, help_stderr, help_status = run(help_command)
    help_text = help_stdout + help_stderr
    exposed = [flag for flag in required if exposes(help_text, flag)]
    schema_available = help_code == 0 and help_status == "finished" and len(exposed) == len(required)
    evidence = (
        f"Version exit={version_code}, {version_status}; launcher help exit={help_code}, {help_status}; "
        f"exact flags exposed={','.join(exposed) or 'none'}. Help establishes syntax only; native tool availability unknown."
    )
    result = "unknown"
    technique = args.technique or launcher
    context = f"Manual {args.case} probe; no trust or permission bypass flags."
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
            values = {"model": args.model, "effort": args.effort, "effort_json": json.dumps(args.effort), "prompt": prompt}
            command = [token.format(**values) for token in template]
            event_paths = [Path(str(args.output) + suffix) for suffix in (".events.stdout", ".events.stderr")]
            context += " Event streams: " + ", ".join(path.name for path in event_paths) + " (operator-held, not for commit)."
            code, stdout, stderr, status = run(command, event_paths)
            evidence += (
                f" Authenticated launcher exit={code}, {status}; nonce present in "
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
        "source": "Manual opt-in runner: replay commands regenerate version/help output; authenticated stdout/stderr retained as operator-held event streams, not for commit.",
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
