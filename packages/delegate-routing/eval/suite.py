#!/usr/bin/env python3
"""Delegate-routing acceptance suite: one real session per case.

Each case runs in a fresh fixture repository rendered from the repository's
delivered configuration, under a scratch HOME that keeps only the login and carried-over settings. It
hides config from the loader, not files from the model. See
README.md for the isolation recipe, the caps and the operator steps.
"""

# cspell:ignore AUTOINSTALL CLAUDEAI collab killpg realise setsid
import argparse
from datetime import datetime, timezone
import fnmatch
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import tomllib

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
REAL_HOME = Path.home()
CHECK = "delegate-routing-eval-structure"
NIX_ENV = {**os.environ, "NIX_CONFIG": os.environ.get("NIX_CONFIG", "") + "\nmax-jobs = 1\ncores = 2\n"}

# Root controls only; delegate choices still come from the delivered skill.
ROOT_BASELINES = {
    "claude": {
        "argv": ["--model", "{model}", "--effort", "{effort}"],
        "effort": "medium",
        "model": "opus",
    },
    "codex": {
        "argv": ["--model", "{model}", "-c", 'model_reasoning_effort="{effort}"'],
        "effort": "medium",
        "model": "gpt-6.1-sol",
    },
    "kimchi": {
        "argv": ["--model", "{model}", "--thinking", "{effort}"],
        "effort": "medium",
        "model": "kimi-k3",
    },
    "kiro": {
        "argv": ["--model", "{model}", "--effort", "{effort}"],
        "effort": "medium",
        "listModels": ["chat", "--list-models", "-f", "json"],
        "model": "claude-opus-*",
    },
}

# Caps on every run, all four harnesses.
WALL_SECONDS = 600
KILL_GRACE_SECONDS = 30
TURN_CAP = 40
BUDGET_USD = 5
DEFAULT_ROOT = Path("/var/tmp/delegate-routing-suite")

# Personal configuration roots under the real HOME. A scratch HOME hides them;
# any of these paths showing up in a run's logs is a leak.
PERSONAL_ROOTS = [".agents", ".claude", ".claude.json", ".codex", ".config/kimchi", ".config/kiro", ".kiro", ".pi"]
PERSONAL_SKILL_DIRS = [".agents/skills", ".claude/skills", ".codex/skills", ".config/kimchi/harness/skills", ".kiro/skills", ".pi/agent/skills"]


# --- small helpers -----------------------------------------------------------

def encode(value):
    return json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(encode(value))


def read_json(path, default=None):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return default


def toml_value(value):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value)
    if isinstance(value, list):
        return "[" + ", ".join(toml_value(item) for item in value) + "]"
    raise ValueError(f"cannot write {type(value).__name__} as TOML")


def toml_lines(table, prefix=()):
    key = lambda name: name if re.fullmatch(r"[A-Za-z0-9_-]+", name) else json.dumps(name)
    lines = [f"{key(name)} = {toml_value(value)}" for name, value in table.items() if not isinstance(value, dict)]
    for name, value in table.items():
        if isinstance(value, dict):
            path = (*prefix, name)
            lines += ["", "[" + ".".join(map(key, path)) + "]", *toml_lines(value, path)]
    return lines


def toml_dump(table):
    """A nested dict of scalars, lists and tables, as TOML."""
    return "\n".join(toml_lines(table)).strip() + "\n"


def personal_names():
    """Names of the operator's personal skills, MCP servers, plugins and agents.

    Keeps names only; no credential store is opened."""
    names = set()
    for directory in PERSONAL_SKILL_DIRS:
        try:
            names |= {entry.name for entry in (REAL_HOME / directory).iterdir() if not entry.name.startswith(".")}
        except OSError:
            pass
    claude_state = read_json(REAL_HOME / ".claude.json", {}) or {}
    names |= set(claude_state.get("mcpServers", {}))
    for project in (claude_state.get("projects") or {}).values():
        names |= set((project or {}).get("mcpServers", {}))
    for path in (REAL_HOME / ".kiro/settings/mcp.json", REAL_HOME / ".config/kimchi/harness/mcp.json"):
        names |= set((read_json(path, {}) or {}).get("mcpServers", {}))
    try:
        names |= set(tomllib.loads((REAL_HOME / ".codex/config.toml").read_text()).get("mcp_servers", {}))
    except (OSError, ValueError):
        pass
    names |= {name.split("@")[0] for name in (read_json(REAL_HOME / ".claude/settings.json", {}) or {}).get("enabledPlugins", {})}
    for directory, suffix in ((".claude/agents", ".md"), (".kiro/agents", ".json")):
        try:
            names |= {entry.name.removesuffix(suffix) for entry in (REAL_HOME / directory).iterdir() if entry.name.endswith(suffix)}
        except OSError:
            pass
    return {name for name in names if len(name) >= 4}


# --- per-harness configuration ----------------------------------------------
# Each setup builds the scratch configuration, argv and environment for one
# harness from a case context.

def claude_setup(ctx):
    behavior = read_json(REAL_HOME / ".claude/settings.json", {}) or {}
    overlay = {
        "autoMemoryEnabled": False,
        "disableClaudeAiConnectors": True,
        "enableAllProjectMcpServers": True,
        # The operator's behavior keys, so the run matches a normal session.
        **{key: behavior[key] for key in ("enableWorkflows", "ultracode") if key in behavior},
        "hooks": {"PreToolUse": [{"matcher": ".*", "hooks": [{"type": "command", "command": str(ctx["hook"])}]}]},
    }
    write_json(ctx["dir"] / "claude-overlay.json", overlay)
    return {
        "argv": [ctx["exe"], "-p", "--setting-sources", "project", "--settings", str(ctx["dir"] / "claude-overlay.json"),
                 *ctx["baseline_argv"], "--permission-mode", "auto", "--max-turns", str(TURN_CAP),
                 "--max-budget-usd", str(BUDGET_USD), "--no-session-persistence", "--output-format", "stream-json",
                 "--verbose", "--include-hook-events", "--forward-subagent-text", ctx["prompt"]],
        "env": {
            "CLAUDE_CODE_DISABLE_AUTO_MEMORY": "1",
            "CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL": "1",
            "CLAUDE_CODE_DISABLE_ORG_MEMORY": "1",
            "CLAUDE_CODE_DISABLE_POLICY_SKILLS": "1",
            "CLAUDE_CONFIG_DIR": str(ctx["home"] / ".claude"),
            "ENABLE_CLAUDEAI_MCP_SERVERS": "false",
        },
        "secrets": {"CLAUDE_CODE_OAUTH_TOKEN": ctx["claude_token"]},
        "written": [ctx["dir"] / "claude-overlay.json"],
    }


def codex_setup(ctx):
    try:
        real = tomllib.loads((REAL_HOME / ".codex/config.toml").read_text())
    except (OSError, ValueError):
        real = {}
    # The operator's permissions and behavior; no MCP servers, project
    # trust list or UI keys.
    config = {key: real[key] for key in ("agents", "default_permissions", "features", "permissions") if key in real}
    config["approval_policy"] = "never"
    # Trust belongs in config.toml: trust passed with -c skips the project config.
    config["projects"] = {str(ctx["repo"]): {"trust_level": "trusted"}}
    codex_home = ctx["home"] / ".codex"
    codex_home.mkdir(parents=True, exist_ok=True)
    (codex_home / "config.toml").write_text(toml_dump(config))
    # A symlink, never a copy: auth.json is rewritten in place, so a refresh
    # reaches the real file instead of rotating the operator's token.
    auth = codex_home / "auth.json"
    if not auth.is_symlink():
        auth.symlink_to(REAL_HOME / ".codex/auth.json")
    flags = ["--disable", "apps", "--disable", "plugins", "--disable", "remote_plugin", "--disable", "memories",
             "-c", "memories.use_memories=false", "-c", "memories.generate_memories=false"]
    return {
        "argv": [ctx["exe"], "exec", *ctx["baseline_argv"], *flags, "--json", "-o", str(ctx["logs"] / "last-message.txt"), ctx["prompt"]],
        "env": {"CODEX_HOME": str(codex_home)},
        # Renders the model-visible prompt with no model call: the startup record.
        "preflight": [ctx["exe"], *ctx["baseline_argv"], "debug", "prompt-input", *flags],
        "written": [codex_home / "config.toml", auth],
    }


def kiro_setup(ctx):
    real = read_json(REAL_HOME / ".kiro/settings/cli.json", {}) or {}
    settings = ctx["home"] / ".kiro/settings/cli.json"
    write_json(settings, {key: real[key] for key in ("chat.enableCheckpoint", "chat.enableTangentMode", "chat.enableWorkflows") if key in real})
    hook = ctx["repo"] / ".kiro/hooks/suite-log.json"
    write_json(hook, {"version": "v1", "hooks": [{"name": "suite-log", "trigger": "PreToolUse", "action": {"type": "command", "command": str(ctx["hook"])}}]})
    data = Path(os.environ.get("XDG_DATA_HOME") or REAL_HOME / ".local/share")
    env = {
        # The real data dir holds the login, so refreshes land in the one
        # database the operator already uses. Copied auth rows could rotate it.
        "KIRO_CHAT_LOG_FILE": str(ctx["logs"] / "chat.log"),
        "KIRO_DATA_DIR": str(data / "kiro-cli"),
        "KIRO_DISABLE_TELEMETRY": "1",
        "KIRO_LOG_LEVEL": "debug",
        "KIRO_NO_AUTO_UPDATE": "1",
        "KIRO_NO_REMOTE_CHANGELOG": "1",
        "XDG_DATA_HOME": str(data),
    }
    return {
        "argv": [ctx["exe"], "chat", *ctx["baseline_argv"], "--v3", "--no-interactive", "--trust-all-tools", "--output-format", "stream-json", ctx["prompt"]],
        "env": env,
        "written": [settings, hook],
    }


def kimchi_setup(ctx):
    harness = ctx["home"] / ".config/kimchi/harness"
    write_json(harness.parent / "config.json", {
        "migrationState": "skip-forever", "region": "us", "telemetry": {"enabled": False},
        "skillPaths": [".config/kimchi/harness/skills", ".pi/agent/skills", ".claude/skills"],
    })
    settings = read_json(REAL_HOME / ".config/kimchi/harness/settings.json", {}) or {}
    settings.setdefault("resources", {})["extensions.memory"] = False
    write_json(harness / "settings.json", settings)
    return {
        # --auto: the closest posture to a normal interactive session.
        "argv": [ctx["exe"], "-p", *ctx["baseline_argv"], "--mode", "json", "--approve", "--auto", ctx["prompt"]],
        "env": {"KIMCHI_NO_UPDATE_CHECK": "1", "KIMCHI_TAGS": f"suite:delegate-routing,case:{ctx['case']['id']}", "KIMCHI_TELEMETRY_ENABLED": "0"},
        # Session-only: an env key is never written back to the real config.
        "secrets": {"KIMCHI_API_KEY": ("json", REAL_HOME / ".config/kimchi/config.json", "apiKey")},
        "written": [harness.parent / "config.json", harness / "settings.json"],
    }


def claude_init(events):
    return next((event for event in events if event.get("type") == "system" and event.get("subtype") == "init"), None)


HARNESSES = {
    "claude": {
        "exe": "claude",
        "setup": claude_setup,
        "skill": ".claude/skills/delegate-routing/SKILL.md",
        # Delegates' own messages are forwarded with parent_tool_use_id; only
        # the session's own calls count.
        "calls": lambda event: [] if event.get("parent_tool_use_id") or event.get("type") != "assistant" else
                 [{"id": block.get("id"), "name": block.get("name"), "input": block.get("input")}
                  for block in (event.get("message") or {}).get("content") or [] if block.get("type") == "tool_use"],
        "answered": lambda events: any(event.get("type") == "result" and event.get("subtype") == "success" and not event.get("is_error") for event in events),
        "startup": lambda events, logs: encode(claude_init(events)) if claude_init(events) else None,
        "archive": [],
        "turns": None,
    },
    "codex": {
        "exe": "codex",
        "setup": codex_setup,
        "skill": ".agents/skills/delegate-routing",
        "calls": lambda event: [{"id": item.get("id"), "name": item.get("tool"), "input": {"command": item.get("command")}}
                                for item in [event.get("item") or {}]
                                if event.get("type") == "item.started" and item.get("type") in {"collab_tool_call", "command_execution"}],
        "answered": lambda events: any(event.get("type") == "turn.completed" for event in events) and not any(event.get("type") == "turn.failed" for event in events),
        "startup": lambda events, logs: (logs / "prompt-input.json").read_text() if (logs / "prompt-input.json").is_file() else None,
        "archive": [".codex/sessions"],
        "turns": None,
    },
    "kimchi": {
        "exe": "kimchi",
        "setup": kimchi_setup,
        "skill": ".kimchi/skills/delegate-routing/SKILL.md",
        "calls": lambda event: [{"id": event.get("toolCallId"), "name": event.get("toolName"), "input": event.get("args")}] if event.get("type") == "tool_execution_start" else [],
        "answered": lambda events: any(event.get("type") == "agent_end" for event in events),
        # The JSON stream starts with a session header, not the loaded context.
        "startup": lambda events, logs: None,
        "archive": [".config/kimchi/harness/sessions"],
        "turns": None,
    },
    "kiro": {
        "exe": "kiro-cli",
        "setup": kiro_setup,
        "skill": ".kiro/skills/delegate-routing/SKILL.md",
        "calls": lambda event: [{"id": update.get("toolCallId"), "name": [update.get(key) for key in ("name", "title", "toolName", "tool_name")] + [str(value) for value in (update.get("_meta") or {}).values()], "input": update.get("rawInput")}
                                for update in [((event.get("params") or {}).get("update") or {})] if update.get("sessionUpdate") == "tool_call"],
        "answered": lambda events: any(isinstance(event.get("result"), dict) and event["result"].get("stopReason") == "end_turn" for event in events),
        "startup": lambda events, logs: (logs / "chat.log").read_text(errors="ignore") if (logs / "chat.log").is_file() else None,
        "archive": [".kiro/sessions"],
        # No native turn cap: the watcher stops the run at TURN_CAP tool calls.
        "turns": lambda event: ((event.get("params") or {}).get("update") or {}).get("sessionUpdate") == "tool_call",
    },
}


# --- assertions on the session's own logs ------------------------------------

ASSERTIONS = {
    "codex-lane": ("an external `codex exec` launch was attempted", lambda calls: any(call["runtime"] == "codex" and call["kind"] == "external" for call in calls)),
    "delegate": ("at least one delegate technique was invoked (subagent, workflow or external)", lambda calls: bool(calls)),
    "observe": ("none: records the delegates and passes once the session answers", lambda calls: True),
    "one-delegate": ("exactly one subagent or external delegate, and no workflow", lambda calls: len(calls) == 1 and calls[0]["kind"] != "workflow"),
    "workflow": ("a workflow technique, or at least two delegates", lambda calls: any(call["kind"] == "workflow" for call in calls) or len(calls) >= 2),
}


def commands(value):
    if isinstance(value, dict):
        for key, item in value.items():
            if key in {"command", "cmd"} and isinstance(item, (str, list)):
                yield item if isinstance(item, str) else shlex.join(map(str, item))
            else:
                yield from commands(item)
    elif isinstance(value, list):
        for item in value:
            yield from commands(item)


def classify(case, calls):
    """Delegate calls among the session's tool calls, by the delivered techniques."""
    own = case["techniques"].get(case["runtime"], {})
    external = [(runtime, name, re.compile(r"(?:^|[\s;&|(`'\"/])" + r"\s+".join(map(re.escape, name.split())) + r"(?:\s|$)"))
                for runtime, techniques in case["techniques"].items() for name, kind in techniques.items() if kind == "external"]
    seen, found = set(), []
    for call in calls:
        if call["id"] is not None and call["id"] in seen:
            continue
        seen.add(call["id"])
        names = call["name"] if isinstance(call["name"], list) else [call["name"]]
        native = next((name for name in names if name in own and own[name] != "external"), None)
        if native:
            found.append({"id": call["id"], "kind": own[native], "runtime": case["runtime"], "technique": native})
            continue
        for command in commands(call["input"]):
            match = next(((runtime, name) for runtime, name, pattern in external if pattern.search(command)), None)
            if match:
                found.append({"command": command, "id": call["id"], "kind": "external", "runtime": match[0], "technique": match[1]})
                break
    return found


def parse_lines(text):
    """JSON values from a log, one per line; a multi-line value is decoded whole."""
    decoder, values, index = json.JSONDecoder(), [], 0
    while index < len(text):
        while index < len(text) and text[index].isspace():
            index += 1
        if index >= len(text):
            break
        try:
            value, index = decoder.raw_decode(text, index)
            values.append(value)
        except ValueError:
            index = text.find("\n", index) + 1 or len(text)
    return [value for value in values if isinstance(value, dict)]


def observed_controls(runtime, events, logs):
    """Reported root controls, never inferred from argv or copied settings.

    Keep distinct values if the root changes models during a run. Missing
    fields stay explicit, including effort on streams that only report model.
    """
    records = []
    own = [event for event in events if not event.get("parent_tool_use_id")]
    if runtime == "claude":
        records = [claude_init(own) or {}]
    elif runtime == "kimchi":
        records = [event for event in own if event.get("type") in {"agent_start", "agent_end"}]
    elif runtime == "codex":
        types = {"session_meta", "session_configured", "turn_context", "turn.started", "turn.completed", "session.started"}
        records = [event.get("payload") or event.get("turn") or event.get("session") or event for event in own if event.get("type") in types]
        # exec's stream may omit controls; archived root turn_context exposes
        # them. Match the root thread, never a delegate's rollout.
        root_id = next((event.get("thread_id") for event in own if event.get("type") == "thread.started"), None)
        for path in sorted((logs / "sessions").rglob("*.jsonl")):
            session = parse_lines(path.read_text(errors="ignore"))
            meta = next((event.get("payload") or {} for event in session if event.get("type") == "session_meta"), {})
            if root_id and meta.get("id") == root_id:
                records += [event.get("payload") or {} for event in session if event.get("type") in types]
    elif runtime == "kiro":
        path = logs / "chat.log"
        text = path.read_text(errors="ignore") if path.is_file() else ""
        # qChatLogger writes [DEBUG] [QChat] {request: {conversationState: ...}}.
        # Read only the current user message, never history or tool arguments.
        text = re.sub(r"^\[DEBUG\] \[QChat\] ", "", text, flags=re.MULTILINE)
        root_id = None
        for event in parse_lines(text):
            request = event.get("request") or {}
            state = request.get("conversationState") or {}
            current = (state.get("currentMessage") or {}).get("userInputMessage") or {}
            model = current.get("modelId")
            if not model:
                continue
            identity = state.get("conversationId")
            if not records:
                root_id = identity
            elif root_id is None or identity != root_id:
                continue
            extra = request.get("additionalModelRequestFields") or {}
            effort = (extra.get("output_config") or {}).get("effort") or request.get("effortLevel")
            records.append({"model": model, "effort": effort})
    values = {"model": [], "effort": []}
    for record in records:
        # Restrict nesting to event control fields; never scan messages/tools.
        settings = record.get("settings") or {}
        model = record.get("model") or record.get("model_id") or record.get("modelId") or settings.get("model")
        if isinstance(model, dict):
            model = model.get("id") or model.get("model_id")
        effort = next((record.get(key) or settings.get(key) for key in
                       ("effort", "reasoning_effort", "model_reasoning_effort", "effortLevel", "thinkingLevel")
                       if record.get(key) or settings.get(key)), None)
        for key, value in (("model", model), ("effort", effort)):
            if isinstance(value, str) and value not in values[key]:
                values[key].append(value)
    return {key: ", ".join(value) if value else "not exposed" for key, value in values.items()}


def control_record(runtime, requested=None):
    baseline = ROOT_BASELINES[runtime]
    return {"requested": requested or {key: baseline[key] for key in ("model", "effort")},
            "observed": {key: "not exposed" for key in ("model", "effort")}}


# --- fixture -----------------------------------------------------------------

def render_fixture(case, root, state):
    for file in case["files"]:
        path = root / file["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        if "renderCommand" in file:
            rendered = subprocess.run([file["renderShell"], "-c", "set -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\n" + file["renderCommand"]],
                                      capture_output=True, text=True, check=False, timeout=60,
                                      env={**os.environ, "NAT_OWN_ROOT": str(root), "NAT_OWN_STATE": str(state)})
            if rendered.returncode:
                raise ValueError(f"config renderer failed for {file['path']}: {rendered.stderr}")
            path.write_text(rendered.stdout)
        elif "sourcePath" in file:
            # devenv delivers these as store symlinks; so does the fixture.
            path.symlink_to(file["sourcePath"])
        else:
            path.write_text(file["text"])


def validate(cases):
    if not isinstance(cases, list) or not cases:
        raise ValueError("cases must be a nonempty list")
    ids = set()
    for case in cases:
        where = f"case {case.get('id')!r}"
        if case.get("id") in ids:
            raise ValueError(f"{where}: duplicate id")
        ids.add(case["id"])
        if case.get("runtime") not in HARNESSES:
            raise ValueError(f"{where}: unknown runtime {case.get('runtime')!r}")
        if case.get("expect") not in ASSERTIONS:
            raise ValueError(f"{where}: unknown assertion {case.get('expect')!r}")
        if not isinstance(case.get("task"), str) or not case["task"].strip():
            raise ValueError(f"{where}: empty task")
        own = case.get("techniques", {}).get(case["runtime"])
        if not own:
            raise ValueError(f"{where}: no delegate techniques for {case['runtime']}")
        if case["expect"] == "codex-lane" and "external" not in case["techniques"].get("codex", {}).values():
            raise ValueError(f"{where}: codex-lane needs an external codex technique")
        paths = set()
        for file in case["files"]:
            path = Path(file["path"])
            if path.is_absolute() or ".." in path.parts or str(path) in paths:
                raise ValueError(f"{where}: unsafe or duplicate path {path}")
            paths.add(str(path))
            if sum(key in file for key in ("renderCommand", "sourcePath", "text")) != 1:
                raise ValueError(f"{where}: {path} needs exactly one of text, sourcePath, renderCommand")
        if HARNESSES[case["runtime"]]["skill"] not in paths:
            raise ValueError(f"{where}: delivered routing skill {HARNESSES[case['runtime']]['skill']} missing")


def load_cases(path):
    if path:
        return json.loads(Path(path).read_text())
    result = subprocess.run(["nix", "eval", "--json", f".#checks.x86_64-linux.{CHECK}.passthru.cases"],
                            cwd=REPO, capture_output=True, text=True, timeout=600, check=False, env=NIX_ENV)
    if result.returncode:
        raise ValueError(f"case evaluation failed: {result.stderr}")
    cases = json.loads(result.stdout)
    if any("sourcePath" in file and not os.path.lexists(file["sourcePath"]) for case in cases for file in case["files"]):
        # The check's inputs carry every generated-config dependency. Realize
        # them only; no package output or model is started.
        drv = subprocess.run(["nix", "eval", "--raw", f".#checks.x86_64-linux.{CHECK}.drvPath"], cwd=REPO,
                             capture_output=True, text=True, timeout=600, check=True, env=NIX_ENV).stdout.strip()
        inputs = subprocess.run(["nix-store", "--query", "--references", drv], capture_output=True, text=True, check=True, env=NIX_ENV).stdout.split()
        subprocess.run(["nix-store", "--realise", *inputs], check=True, capture_output=True, timeout=3600, env=NIX_ENV)
    return cases


# --- one case ----------------------------------------------------------------

def resolve(name, overrides, live):
    path = overrides.get(name) or shutil.which(name)
    if not path:
        if live:
            raise LookupError(f"{name} not found on PATH; pass --bin {name}=<path>")
        return f"UNRESOLVED({name})"
    real = os.path.realpath(path)
    # A Nix-pinned binary; ~/.local/bin holds a stale native Claude install.
    if live and name not in overrides and not real.startswith("/nix/store/"):
        raise LookupError(f"{name} resolves to {real}, outside /nix/store; pass --bin {name}=<path>")
    return path


# Secrets are read only at launch, from where the operator keeps them; a dry
# run prints where each one comes from, never its value.
def secret_value(spec):
    kind, source, *rest = spec
    if kind == "env":
        return os.environ.get(source)
    if kind == "file":
        return Path(source).read_text().strip()
    if kind == "json":
        return (read_json(source, {}) or {}).get(rest[0])
    raise ValueError(f"unknown secret source {kind!r}")


def describe_secret(spec):
    if spec is None:
        return "<MISSING: pass --claude-token-file or export CLAUDE_CODE_OAUTH_TOKEN>"
    kind, source, *rest = spec
    return {"env": f"<redacted: ${source}>", "file": f"<redacted: contents of {source}>",
            "json": f"<redacted: {rest[0] if rest else ''} from {source}>"}[kind] + ", read at launch"


def prepare(case, out, args, live):
    harness = HARNESSES[case["runtime"]]
    directory = out / case["id"]
    ctx = {"case": case, "dir": directory, "home": directory / "home", "logs": directory / "logs", "repo": directory / "repo"}
    for key in ("home", "logs", "repo"):
        ctx[key].mkdir(parents=True)
    (directory / "tmp").mkdir()
    render_fixture(case, ctx["repo"], directory / "state")
    (ctx["home"] / ".gitconfig").write_text("[user]\n\tname = suite\n\temail = suite@invalid\n")
    ctx["hook"] = directory / "log-hook"
    # Log-only: records each tool request and always exits 0.
    ctx["hook"].write_text(f"#!/usr/bin/env bash\nset -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\n{{ cat; printf '\\n'; }} >>{shlex.quote(str(ctx['logs'] / 'hook-calls.jsonl'))} || :\n")
    ctx["hook"].chmod(0o755)
    ctx["exe"] = resolve(harness["exe"], args.bin, live)
    baseline = ROOT_BASELINES[case["runtime"]]
    ctx["requested"] = {key: baseline[key] for key in ("model", "effort")}
    if live and baseline.get("listModels"):
        listed = subprocess.run([ctx["exe"], *baseline["listModels"]], capture_output=True, text=True, check=True, timeout=60)
        # The CLI's .models[].model_id, with numeric version ordering (4.10 > 4.9).
        models = [row["model_id"] for row in json.loads(listed.stdout)["models"]
                  if fnmatch.fnmatchcase(row["model_id"], baseline["model"])]
        if not models:
            raise ValueError(f"no model matches {baseline['model']}")
        ctx["requested"]["model"] = max(models, key=lambda model: (tuple(map(int, re.findall(r"\d+", model))), model))
    ctx["baseline_argv"] = [arg.format(**ctx["requested"]) for arg in baseline["argv"]]
    ctx["prompt"] = case["task"] + "\n\nCurrent usage (use these numbers; do not run a usage helper):\n" + json.dumps(case["usage"], sort_keys=True)
    # A `claude setup-token` token; ~/.claude credentials are never read.
    ctx["claude_token"] = ("file", args.claude_token_file) if args.claude_token_file else (
        ("env", "CLAUDE_CODE_OAUTH_TOKEN") if os.environ.get("CLAUDE_CODE_OAUTH_TOKEN") else None)
    plan = harness["setup"](ctx)
    git = ["git", "-c", "user.name=suite", "-c", "user.email=suite@invalid", "-C", str(ctx["repo"])]
    for argv in (["init", "-q", "-b", "main"], ["add", "-A"], ["commit", "-q", "-m", "fixture", "--no-verify"]):
        subprocess.run(git + argv, check=True, capture_output=True, timeout=60)
    env = {
        "DEVENV_ROOT": str(ctx["repo"]),
        "HOME": str(ctx["home"]),
        "LANG": os.environ.get("LANG", "C.UTF-8"),
        "PATH": os.environ.get("PATH", ""),
        "TERM": "dumb",
        "TMPDIR": str(directory / "tmp"),
        "USER": os.environ.get("USER", "suite"),
        "XDG_CACHE_HOME": str(ctx["home"] / ".cache"),
        "XDG_CONFIG_HOME": str(ctx["home"] / ".config"),
        "XDG_DATA_HOME": str(ctx["home"] / ".local/share"),
        "XDG_STATE_HOME": str(ctx["home"] / ".local/state"),
        **plan["env"],
    }
    return {"secrets": {}, **plan, "ctx": ctx, "env": env}


def kill_group(process, grace):
    try:
        os.killpg(process.pid, signal.SIGTERM if grace else signal.SIGKILL)
    except ProcessLookupError:
        return
    if grace:
        try:
            process.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            pass
        kill_group(process, 0)


def launch(argv, env, cwd, logs, turns):
    """Run one session in its own process group under the caps."""
    stop = []
    with (logs / "events.jsonl").open("wb") as events, (logs / "stderr.txt").open("wb") as stderr:
        process = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=stderr, start_new_session=True)

        def pump():
            count = 0
            for line in process.stdout:
                events.write(line)
                events.flush()
                if turns:
                    try:
                        count += bool(turns(json.loads(line)))
                    except ValueError:
                        pass
                    if count >= TURN_CAP and not stop:
                        stop.append(f"turn cap {TURN_CAP}")
                        kill_group(process, KILL_GRACE_SECONDS)

        reader = threading.Thread(target=pump, daemon=True)
        reader.start()
        try:
            process.wait(timeout=WALL_SECONDS)
        except subprocess.TimeoutExpired:
            stop.append(f"wall cap {WALL_SECONDS}s")
            kill_group(process, KILL_GRACE_SECONDS)
        # Delegates still running when the session ends die with it.
        kill_group(process, 0)
        reader.join(timeout=KILL_GRACE_SECONDS)
    return process.returncode, stop


def leaks(case, harness, events, logs, fixture_text):
    found = []
    roots = [str(REAL_HOME / root) for root in PERSONAL_ROOTS]
    for path in sorted(logs.rglob("*")):
        if path.is_file():
            text = path.read_text(errors="ignore")
            found += [f"{root} in {path.relative_to(logs)}" for root in roots if root in text]
    startup = harness["startup"](events, logs)
    if startup:
        if case["runtime"] == "claude":
            init = claude_init(events) or {}
            loaded = set(init.get("skills", [])) | set(init.get("agents", []))
            loaded |= {item["name"] for key in ("mcp_servers", "plugins") for item in init.get(key, [])}
            delivered = {part for file in case["files"] for part in Path(file["path"]).parts}
            delivered |= {Path(part).stem for part in delivered if Path(part).suffix in {".md", ".json"}}
            mcp = next((file for file in case["files"] if file["path"] == ".mcp.json"), None)
            if mcp:
                delivered |= set((read_json(logs.parent / "repo/.mcp.json", {}) or {}).get("mcpServers", {}))
            found += [f"personal name {name!r} in the startup record" for name in sorted(personal_names() & loaded - delivered)]
        else:
            for name in sorted(personal_names()):
                if name not in fixture_text and re.search(r"(?<![\w-])" + re.escape(name) + r"(?![\w-])", startup):
                    found.append(f"personal name {name!r} in the startup record")
    return found, startup


def skill_delivery(case, ctx, events, startup):
    if case["runtime"] == "kimchi":
        return "unverified: no startup record"
    if case["runtime"] == "claude":
        delivered = "delegate-routing" in (claude_init(events) or {}).get("skills", [])
    else:
        skill = ctx["repo"] / HARNESSES[case["runtime"]]["skill"]
        if skill.is_dir():
            skill /= "SKILL.md"
        frontmatter = skill.read_text().split("---", 2)[1]
        match = re.search(r"^description:\s*(.*(?:\n[ \t]+[^\n]*)*)", frontmatter, re.MULTILINE)
        description = " ".join(match.group(1).split()) if match else ""
        if description.startswith('"'):
            description = json.loads(description)
        elif description.startswith("'"):
            description = description[1:-1].replace("''", "'")
        elif description.startswith((">", "|")):
            description = description.split(" ", 1)[1] if " " in description else ""
        delivered = bool(description) and " ".join(description.split()) in " ".join((startup or "").split())
    return "loaded" if delivered else "missing"


def raw_tool_names(value):
    """Read diagnostic tool names without relying on the delegate extractor."""
    if isinstance(value, dict):
        for key in ("tool", "tool_name", "toolName"):
            if isinstance(value.get(key), str):
                yield value[key]
        if value.get("type") in {"tool_use", "collab_tool_call", "command_execution"}:
            yield value.get("name") or value["type"]
        if value.get("sessionUpdate") == "tool_call":
            for key in ("name", "title"):
                if isinstance(value.get(key), str):
                    yield value[key]
        for item in value.values():
            yield from raw_tool_names(item)
    elif isinstance(value, list):
        for item in value:
            yield from raw_tool_names(item)


def run_case(case, prepared, args):
    harness, ctx = HARNESSES[case["runtime"]], prepared["ctx"]
    logs = ctx["logs"]
    env = dict(prepared["env"])
    for name, spec in prepared["secrets"].items():
        value = spec and secret_value(spec)
        if value:
            env[name] = value
        else:
            return {"status": "ERROR", "detail": f"{name} unavailable: {describe_secret(spec)}"}
    version = subprocess.run([ctx["exe"], "--version"], capture_output=True, text=True, timeout=60, check=False, env=env, cwd=ctx["repo"])
    record = {"executable": ctx["exe"], "version": version.stdout.strip() or version.stderr.strip()}
    if prepared.get("preflight"):
        result = subprocess.run(prepared["preflight"], cwd=ctx["repo"], env=env, capture_output=True, timeout=120, check=False, stdin=subprocess.DEVNULL)
        (logs / "prompt-input.json").write_bytes(result.stdout)
        if result.returncode:
            return {**record, "status": "ERROR", "detail": f"preflight exited {result.returncode}: {result.stderr.decode(errors='ignore')[-500:]}"}
    code, stop = launch(prepared["argv"], env, ctx["repo"], logs, harness["turns"])
    for relative in harness["archive"]:
        if (ctx["home"] / relative).is_dir():
            shutil.copytree(ctx["home"] / relative, logs / Path(relative).name, symlinks=True)
    events = parse_lines((logs / "events.jsonl").read_text(errors="ignore"))
    hook_calls = parse_lines((logs / "hook-calls.jsonl").read_text(errors="ignore")) if (logs / "hook-calls.jsonl").exists() else []
    raw_calls = [call for event in events for call in harness["calls"](event)]
    calls = classify(case, raw_calls)
    fixture_text = "\n".join(file["path"] + "\n" + file.get("text", "") for file in case["files"]) + "".join(
        path.read_text(errors="ignore") for path in ctx["repo"].rglob("*") if path.is_file() and ".git" not in path.parts)
    leaked, startup = leaks(case, harness, events, logs, fixture_text)
    delivery = skill_delivery(case, ctx, events, startup)
    record.update({
        "delegates": calls, "delivery": delivery, "exitCode": code, "leaks": leaked, "stop": stop,
        "observed": observed_controls(case["runtime"], events, logs),
        # Second, independent record; not counted, so a call is never counted twice.
        "hookDelegates": classify(case, [{"id": None, "name": call.get("tool_name") or call.get("toolName"), "input": call.get("tool_input") or call} for call in hook_calls]),
    })
    if leaked:
        return {**record, "status": "ERROR", "detail": "personal state leaked: " + "; ".join(leaked[:3])}
    if delivery == "missing":
        return {**record, "status": "ERROR", "detail": "the fixture's delegate-routing skill is absent from the startup record"}
    if record["hookDelegates"] and not calls:
        return {**record, "status": "ERROR", "detail": "event extractor missed delegates the hook saw"}
    if stop or not harness["answered"](events):
        return {**record, "status": "ERROR", "detail": "no answer: " + (", ".join(stop) or f"exit {code}, no completion event")}
    passed = ASSERTIONS[case["expect"]][1](calls)
    names = sorted(set(raw_tool_names(events)))
    summary = ", ".join(f"{call['runtime']}:{call['technique']}" for call in calls) or "no delegates; tools: " + (", ".join(names) or "none")
    return {**record, "status": "PASS" if passed else "FAIL", "detail": summary}


def show(case, prepared):
    ctx = prepared["ctx"]
    lines = [f"== {case['id']} ({case['runtime']}) expect {case['expect']}: {ASSERTIONS[case['expect']][0]}",
             f"cwd: {ctx['repo']}", "argv: " + shlex.join(prepared["argv"])]
    if prepared.get("preflight"):
        lines.append("preflight: " + shlex.join(prepared["preflight"]))
    lines.append("env (nothing else is inherited):")
    lines += [f"  {key}={value}" for key, value in sorted(prepared["env"].items())]
    lines += [f"  {key}={describe_secret(spec)}" for key, spec in sorted(prepared["secrets"].items())]
    turn_cap = f"--max-turns {TURN_CAP}" if "--max-turns" in prepared["argv"] else (f"watcher stops at {TURN_CAP} tool calls" if HARNESSES[case["runtime"]]["turns"] else "none native")
    lines.append(f"caps: wall {WALL_SECONDS}s then process-group kill after {KILL_GRACE_SECONDS}s; turns: {turn_cap}")
    for path in prepared["written"]:
        lines.append(f"scratch file {path}:" + (f" symlink -> {os.readlink(path)}" if path.is_symlink() else "\n    " + path.read_text().rstrip().replace("\n", "\n    ")))
    lines.append(f"fixture: {len(case['files'])} delivered files rendered and committed")
    print("\n".join(lines) + "\n")


def check_location(out):
    resolved = out.resolve()
    if resolved.is_relative_to(REAL_HOME) or resolved.is_relative_to("/tmp"):
        raise ValueError(f"{out}: fixtures must sit outside ~ (ancestor context files) and /tmp (Codex helper refusal)")
    for parent in resolved.parents:
        hits = [name for name in ("AGENTS.md", "CLAUDE.md") if (parent / name).exists()]
        if hits:
            raise ValueError(f"{parent} holds {hits}; harnesses would load it as ancestor context")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bin", action="append", default=[], metavar="NAME=PATH", help="executable override, e.g. claude=/nix/store/.../bin/claude")
    parser.add_argument("--case", action="append", default=[], help="case id (repeatable); default every case")
    parser.add_argument("--claude-token-file", help="file holding a `claude setup-token` token; else $CLAUDE_CODE_OAUTH_TOKEN")
    parser.add_argument("--dry-run", action="store_true", help="validate every case and print each launch; start nothing")
    parser.add_argument("--fixtures", help="case JSON exported from the check; default: evaluate it with Nix")
    parser.add_argument("--harness", action="append", default=[], choices=sorted(HARNESSES), help="harness (repeatable); default all")
    parser.add_argument("--keep", action="store_true", help="keep each case's fixture and scratch HOME")
    parser.add_argument("--out", type=Path, help=f"run directory; default {DEFAULT_ROOT}/<UTC time>")
    args = parser.parse_args()
    args.bin = dict(item.split("=", 1) for item in args.bin)
    cases = load_cases(args.fixtures)
    validate(cases)
    unknown = set(args.case) - {case["id"] for case in cases}
    if unknown:
        raise ValueError(f"unknown cases: {sorted(unknown)}")
    cases = [case for case in cases if (not args.case or case["id"] in args.case) and (not args.harness or case["runtime"] in args.harness)]
    out = args.out or DEFAULT_ROOT / datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    if not args.dry_run:
        check_location(out)
    out.mkdir(parents=True, exist_ok=False)
    results = []
    for case in cases:
        try:
            prepared = prepare(case, out, args, live=not args.dry_run)
        except (LookupError, OSError, ValueError, subprocess.SubprocessError) as error:
            if args.dry_run:
                raise
            results.append({"case": case["id"], "harness": case["runtime"], **control_record(case["runtime"]), "status": "ERROR", "detail": str(error)})
            continue
        if args.dry_run:
            show(case, prepared)
            results.append({"case": case["id"], "harness": case["runtime"], **control_record(case["runtime"], prepared["ctx"]["requested"]), "status": "DRY-RUN", "detail": case["expect"]})
        else:
            try:
                verdict = run_case(case, prepared, args)
            except (OSError, ValueError, subprocess.SubprocessError) as error:
                verdict = {"status": "ERROR", "detail": f"{type(error).__name__}: {error}"}
            results.append({"case": case["id"], "harness": case["runtime"], "expect": case["expect"],
                            **control_record(case["runtime"], prepared["ctx"]["requested"]), **verdict})
            write_json(prepared["ctx"]["logs"] / "verdict.json", results[-1])
            print(f"{case['id']}: {verdict['status']} {verdict['detail']}", file=sys.stderr)
        if not args.keep:
            for name in ("home", "repo", "state", "tmp"):
                shutil.rmtree(out / case["id"] / name, ignore_errors=True)
    write_json(out / "summary.json", results)
    width = max(len(item["case"]) for item in results)
    print(f"{'CASE':<{width}}  HARNESS  RESULT   REQUESTED MODEL / EFFORT -> OBSERVED MODEL / EFFORT  DETAIL")
    for item in results:
        controls = " -> ".join(f"{item[key]['model']} / {item[key]['effort']}" for key in ("requested", "observed"))
        print(f"{item['case']:<{width}}  {item['harness']:<7}  {item['status']:<7}  {controls}  {item['detail']}")
    print(f"\nlogs: {out}")
    return int(any(item["status"] == "ERROR" for item in results))


if __name__ == "__main__":
    sys.exit(main())
