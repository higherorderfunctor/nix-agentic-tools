"""Real vendor harness rendering and explicitly authorized manual capture."""

# cspell:ignore Mcpjson realise  (Claude settings key; nix-store flag)
import json
import os
from pathlib import Path
import random
import re
import shutil
import shlex
import subprocess
import sys

from run import MAX_BYTES, REPO, digest, encode, safe_output, strict_json, utc, write_json

SCHEMA = {
    "type": "object",
    "additionalProperties": False,
    "required": ["caseId", "choice", "delegates", "lane", "rationale", "contextSources"],
    "properties": {
        "caseId": {"type": "string"},
        "choice": {"enum": ["inline", "delegate", "workflow", "external_root"]},
        "contextSources": {"type": "array", "items": {"type": "string"}},
        "delegates": {"type": "array", "items": {"type": "object", "additionalProperties": False,
            "required": ["runtime", "model", "effort", "technique"],
            "properties": {key: {"type": "string"} for key in ("effort", "model", "runtime", "technique")}}},
        "lane": {"enum": ["claude", "codex", "kiro", "UNKNOWN"]},
        "rationale": {"type": "string"},
    },
}

# This hook records requests BEFORE denying them. It never launches a tool.
DENY_SCRIPT = '''#!/usr/bin/env python3
import json
from pathlib import Path
import sys
payload = sys.stdin.read()
with (Path(__file__).parent / "denied-tools.jsonl").open("a") as log:
    log.write(json.dumps({"request": payload}) + "\\n")
print(json.dumps({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "Planning evaluation: execution denied"}}))
print("Planning evaluation: all tool execution denied", file=sys.stderr)
sys.exit(2)
'''


def validate(cases):
    from jsonschema import Draft202012Validator
    Draft202012Validator.check_schema(SCHEMA)
    ids = set()
    for case in cases:
        if case["id"] in ids or case["runtime"] not in {"claude", "kiro"}:
            raise ValueError("invalid vendor identity")
        ids.add(case["id"])
        if case["expected"] not in {"codex-lane", "delegate", "observe", "one-delegate", "workflow"}:
            raise ValueError("unknown vendor assertion")
        paths = set()
        for file in case["files"]:
            path = Path(file["path"])
            if path.is_absolute() or ".." in path.parts or str(path) in paths:
                raise ValueError("unsafe or duplicate config path")
            paths.add(str(path))
            if not isinstance(file.get("text", file.get("sourcePath", file.get("renderCommand"))), str):
                raise ValueError("config text missing")
        prefix = ".claude/" if case["runtime"] == "claude" else ".kiro/"
        if not any(path.startswith(prefix) for path in paths):
            raise ValueError("real runtime delivery missing")
        if not any("delegate-routing" in path and path.endswith("SKILL.md") for path in paths):
            raise ValueError("delivered routing skill missing")
    if not cases:
        raise ValueError("empty vendor set")


def version(runtime):
    executable = shutil.which("claude" if runtime == "claude" else "kiro-cli")
    if not executable:
        return {"executable": "UNKNOWN", "version": "UNKNOWN"}
    result = subprocess.run([executable, "--version"], capture_output=True, text=True, timeout=15, check=False)
    return {"executable": executable, "version": result.stdout.strip() if result.returncode == 0 else "UNKNOWN"}


def render(case, directory, trial):
    root = directory / "workspace"
    root.mkdir()
    sources = []
    for file in case["files"]:
        path = root / file["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        if "renderCommand" in file:
            rendered = subprocess.run([file["renderShell"], "-c", "set -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\n" + file["renderCommand"]],
                                      capture_output=True, text=True, check=False, timeout=30,
                                      env={**os.environ, "NAT_OWN_ROOT": str(root), "NAT_OWN_STATE": str(directory / "state")})
            if rendered.returncode:
                raise ValueError(f"config renderer failed for {file['path']}: {rendered.stderr}")
            path.write_text(rendered.stdout)
            sources.append({"path": file["path"], "sha256": digest(rendered.stdout), "renderCommand": file["renderCommand"], "status": "GENERATED; loading UNKNOWN until observed"})
        elif "sourcePath" in file:
            source = Path(file["sourcePath"])
            if source.is_symlink():
                target = os.readlink(source)
                path.symlink_to(target)
                sources.append({"path": file["path"], "sha256": digest(target), "symlink": target,
                                "status": "GENERATED SYMLINK; target unavailable" if not path.exists() else "GENERATED SYMLINK; loading UNKNOWN"})
            else:
                text = source.read_text()
                path.write_text(text)
                if source.stat().st_mode & 0o111:
                    path.chmod(0o700)
                sources.append({"path": file["path"], "sha256": digest(text), "status": "GENERATED; loading UNKNOWN until observed"})
        else:
            path.write_text(file["text"])
            sources.append({"path": file["path"], "sha256": digest(file["text"]), "status": "GENERATED; loading UNKNOWN until observed"})
    generated_hash = digest(encode(sources))
    hook = directory / "deny-tools.py"
    hook.write_text(DENY_SCRIPT)
    hook.chmod(0o700)
    command = shlex.join([sys.executable, str(hook)])
    if case["runtime"] == "claude":
        settings_path = root / ".claude/settings.json"
        settings = json.loads(settings_path.read_text())
        settings.setdefault("hooks", {}).setdefault("PreToolUse", []).insert(0, {
            "matcher": ".*", "hooks": [{"type": "command", "command": command}],
        })
        # Keep the native tools visible. Noninteractive permission denial and
        # the hook block execution, including external delegates through Bash.
        settings["permissions"] = {"allow": [], "deny": ["Bash", "mcp__*"]}
        settings["disableAllHooks"] = False
        settings["enableAllProjectMcpServers"] = False
        settings["enabledMcpjsonServers"] = []
        write_json(settings_path, settings)
        executable = "claude"
        argv = [executable, "-p", "--model", "opus", "--output-format", "stream-json", "--verbose", "--permission-prompts", "none", "--setting-sources", "project", "--settings", str(settings_path)]
    else:
        # v3 exposes tools but grants none. The PreToolUse hook additionally
        # denies even a tool the vendor may otherwise consider safe/read-only.
        hooks_path = root / ".kiro/hooks/vendor-eval-deny.json"
        hooks_path.parent.mkdir(parents=True, exist_ok=True)
        write_json(hooks_path, {"version": "v1", "hooks": [{"name": "vendor-eval-deny", "trigger": "PreToolUse", "action": {"type": "command", "command": command}}]})
        executable = "kiro-cli"
        argv = [executable, "chat", "--v3", "--no-interactive", "--trust-tools=", "--output-format", "stream-json"]
    prompt = "\n\n".join([
        "Planning evaluation of a fictional task. Return exactly one JSON plan matching the schema. "
        "Describe your routing decision under your normal steering. Do not execute the fictional task. "
        "Tool requests will be recorded and denied. You may read the delivered routing skill below; "
        "it is supplied verbatim because tools are denied. Do not query real usage: use the supplied mock observations.",
        f"Case: {case['id']}; trial: {trial}\n" + case["task"],
        "Mock usage observations:\n" + encode(case["usage"]),
        "Delivered skill:\n" + "\n".join((root / file["path"]).read_text() for file in case["files"] if "delegate-routing" in file["path"] and file["path"].endswith("SKILL.md")),
        "Plan schema:\n" + encode(SCHEMA),
    ])
    argv.append(prompt)
    (directory / "prompt.txt").write_text(prompt)
    effective = {str(path.relative_to(root)): ({"symlink": os.readlink(path)} if path.is_symlink() else path.read_text()) for path in sorted(root.rglob("*")) if path.is_file() or path.is_symlink()}
    config = {"files": effective, "hookContext": case["hookContext"], "switches": case["configSwitches"]}
    identity = {
        "argv": argv, "caseId": case["id"], "configurationSource": case["configurationSource"], "configHash": digest(encode(config)),
        "date": utc(), "generatedConfigHash": generated_hash,
        "safetyProfileHash": digest(encode(config).replace(str(directory), "<TRIAL>")),
        "contextSources": sources + [
            {"path": "prompt.txt", "sha256": digest(prompt), "status": "INJECTED"},
            {"path": "deny-tools.py", "sha256": digest(DENY_SCRIPT), "status": "SAFETY OVERLAY"},
        ],
        "hiddenContext": case["hiddenContext"] + ["user/managed config, plugins, runtime prompt and model resolution UNKNOWN unless transcript exposes them"],
        "hookContext": case["hookContext"], "runtime": case["runtime"], "trial": trial,
        "timeoutSeconds": 120, "outputCapBytes": MAX_BYTES,
        "safety": "all tool requests denied; effective suppression UNKNOWN until matching preflight",
    }
    write_json(directory / "config.json", config)
    write_json(directory / "launch.json", {**identity, "cwd": str(root), "env": {"DEVENV_ROOT": str(root)}})
    return root, identity


def attempted_delegates(events, hook_log):
    # Inspect structured calls, never a substring in an answer's prose.
    calls = []
    def visit(node):
        if isinstance(node, dict):
            if node.get("type") in {"tool_use", "tool_call", "toolCall"} or "toolCallId" in node:
                calls.append(node)
            for value in node.values():
                visit(value)
        elif isinstance(node, list):
            for value in node:
                visit(value)
    visit(events)
    for line in hook_log.splitlines():
        record = json.loads(line)
        try:
            calls.append(json.loads(record["request"]))
        except (ValueError, KeyError):
            calls.append({"unparsedRequest": record})
    delegate_calls = []
    for call in calls:
        name = str(call.get("name", call.get("tool_name", call.get("toolName", call.get("title", "")))))
        body = encode(call).lower()
        external = re.search(r"\b(?:codex\s+exec|claude\s+-p|kiro-cli\s+chat)\b", body)
        if external or any(word in name.lower() for word in ("agent", "delegate", "workflow", "task")) or (
            any(word in name.lower() for word in ("bash", "shell", "execute")) and
            any(word in body for word in ("codex exec", "claude -p", "kiro-cli chat", "delegate"))
        ):
            delegate_calls.append(call)
    return {"calls": calls, "delegateCalls": delegate_calls, "attemptedDelegate": bool(delegate_calls)}


def capture(case, root, identity, directory):
    result = subprocess.run(identity["argv"], cwd=root, env={**os.environ, "DEVENV_ROOT": str(root)},
                            capture_output=True, timeout=120, check=False)
    (directory / "transcript.stdout").write_bytes(result.stdout)
    (directory / "transcript.stderr").write_bytes(result.stderr)
    if len(result.stdout) + len(result.stderr) > MAX_BYTES:
        raise ValueError("vendor transcript exceeds output cap")
    events = [json.loads(line) for line in result.stdout.decode().splitlines() if line.strip()]
    log = directory / "denied-tools.jsonl"
    attempts = attempted_delegates(events, log.read_text() if log.exists() else "")
    write_json(directory / "attempts.json", attempts)
    # Claude's terminal result and Kiro's ACP message chunks are separate
    # formats. Do not repair prose or extract an arbitrary embedded JSON blob.
    terminal = [event for event in events if event.get("type") == "result"]
    if case["runtime"] == "claude":
        if len(terminal) != 1 or terminal[0].get("is_error"):
            raise ValueError("missing/error Claude terminal result")
        raw = terminal[0].get("result", "")
    else:
        chunks = []
        completed = False
        for event in events:
            params = event.get("params", {})
            update = params.get("update", {})
            if update.get("sessionUpdate") == "agent_message_chunk":
                chunks.append(update.get("content", {}).get("text", ""))
            if isinstance(event.get("result"), dict) and event["result"].get("stopReason") == "end_turn":
                completed = True
        if not completed:
            raise ValueError("Kiro terminal completion UNKNOWN: unrecognized ACP stream")
        raw = "".join(chunks)
    (directory / "answer.raw").write_text(raw)
    from jsonschema import Draft202012Validator
    try:
        answer = strict_json(raw)
    except ValueError as error:
        return {"attempts": attempts, "errors": [str(error)], "exitCode": result.returncode, "passed": False}
    errors = list(Draft202012Validator(SCHEMA).iter_errors(answer))
    if errors:
        return {"attempts": attempts, "errors": [error.message for error in errors], "exitCode": result.returncode, "passed": False}
    choice = answer["choice"]
    expected = case["expected"]
    passed = answer["caseId"] == case["id"] and {
        "codex-lane": choice in {"delegate", "external_root", "workflow"} and answer["lane"] == "codex" and any(item["runtime"] == "codex" for item in answer["delegates"]),
        "delegate": (choice in {"delegate", "external_root", "workflow"} and bool(answer["delegates"])) or attempts["attemptedDelegate"],
        "observe": True,
        "one-delegate": choice == "delegate" and len(answer["delegates"]) == 1,
        "workflow": choice == "workflow" and len(answer["delegates"]) >= 2,
    }[expected]
    observed = [{key: event[key] for key in ("agents", "mcp_servers", "model", "plugins", "setting_sources", "skills") if key in event} for event in events if event.get("type") == "system"]
    return {"answer": answer, "attempts": attempts, "observedContextSources": observed, "exitCode": result.returncode, "passed": passed and result.returncode == 0}


def run_vendor(args):
    if args.grade_existing:
        raise ValueError("vendor replay needs raw harness transcripts; --grade-existing belongs to the isolated set")
    if args.runtime or args.model or args.effort:
        raise ValueError("vendor runtimes are case-defined: Claude Opus and Kiro's configured model/effort (resolution recorded as UNKNOWN)")
    if not (args.render_only or args.validate_fixtures) and not (args.allow_paid and args.safety_preflight):
        raise ValueError("vendor live run requires --allow-paid and --safety-preflight; no model started")
    if args.fixtures:
        cases = json.loads(args.fixtures.read_text())
    else:
        result = subprocess.run(["nix", "eval", "--json", ".#checks.x86_64-linux.delegate-routing-vendor-structure.cases"],
                                cwd=REPO, capture_output=True, text=True, timeout=300, check=False,
                                env={**os.environ, "NIX_CONFIG": "max-jobs = 1\ncores = 2"})
        if result.returncode:
            raise ValueError(result.stderr)
        cases = json.loads(result.stdout)
    validate(cases)
    if not args.validate_fixtures and any("sourcePath" in file and not os.path.lexists(file["sourcePath"]) for case in cases for file in case["files"]):
        # Realize only the structural check: its fixture references retain all
        # generated-config dependencies. No package output or model is started.
        drv = subprocess.run(["nix", "eval", "--raw", ".#checks.x86_64-linux.delegate-routing-vendor-structure.drvPath"], cwd=REPO,
                             capture_output=True, text=True, timeout=300, check=True, env={**os.environ, "NIX_CONFIG": "max-jobs = 1\ncores = 2"})
        subprocess.run(["nix-store", "--realise", drv.stdout.strip()], cwd=REPO, check=True, timeout=300,
                       env={**os.environ, "NIX_CONFIG": "max-jobs = 1\ncores = 2"})
    if args.validate_fixtures:
        print(f"Validated {len(cases)} real-harness vendor variants; no model calls")
        return 0
    selected = set(args.case) - {"all"}
    if selected - {case["id"] for case in cases}:
        raise ValueError("unknown vendor case")
    cases = [case for case in cases if not selected or case["id"] in selected]
    out = safe_output(args.out)
    preflight = json.loads(args.safety_preflight.read_text()) if args.safety_preflight else []
    identities = {} if args.render_only else {runtime: version(runtime) for runtime in {case["runtime"] for case in cases}}
    schedule = [(case, trial) for case in cases for trial in range(1, args.repeat + 1)]
    random.Random(args.seed).shuffle(schedule)
    prepared = []
    # Render every variant before allowing the first paid process.
    for case, trial in schedule:
        directory = out / f"{case['id']}-{trial}"
        directory.mkdir()
        root, identity = render(case, directory, trial)
        identity.update(identities.get(case["runtime"], {"executable": "UNKNOWN", "version": "UNKNOWN"}))
        write_json(directory / "identity.json", identity)
        if not args.render_only:
            if identity["version"] == "UNKNOWN" or not any(
                all(record.get(key) == identity[key] for key in ("runtime", "version", "executable", "generatedConfigHash", "safetyProfileHash"))
                and record.get("allToolsDenied") is True and record.get("terminalCaptureVerified") is True
                and record.get("evidenceTranscript") and Path(record["evidenceTranscript"]).is_file()
                for record in preflight
            ):
                raise ValueError(f"no matching suppression/capture preflight: {case['id']}; no model started")
        prepared.append((case, root, identity, directory))
        if args.render_only:
            print(encode({"argv": identity["argv"], "config": json.loads((directory / "config.json").read_text()), "configPath": str(directory / "config.json"), "cwd": str(root), "identity": identity}))
    results = []
    for case, root, identity, directory in prepared:
        record = {"caseId": case["id"], "trial": identity["trial"], "identity": identity}
        if args.render_only:
            record["renderOnly"] = True
        else:
            try:
                record.update(capture(case, root, identity, directory))
            except (ValueError, OSError, subprocess.TimeoutExpired) as error:
                record["infrastructureError"] = str(error)
        write_json(directory / "verdict.json", record)
        results.append(record)
    write_json(out / "summary.json", {"set": "vendor", "trials": results, "comparisons": {
        "clamp": [item for item in results if item["caseId"].startswith("claude-clamp")],
        "poolDrain": [item for item in results if item["caseId"].startswith("claude-ultracode")],
        "workflowReminder": [item for item in results if item["caseId"].startswith("kiro-")],
    }})
    print(f"Saved {len(results)} vendor trials to {out}; paid turns: {0 if args.render_only else len(results)}")
    return int(any(item.get("infrastructureError") or item.get("passed") is False for item in results))
