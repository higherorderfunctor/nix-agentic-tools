"""Kimchi system-prompt map replay (claude:sp-*): every prompt channel, planted as a sentinel, read off the wire.

usage: prompt_map.py [<case>...]       (default: every OFFLINE case; `--list` prints the case names)

Each case writes its drive.py scenario to <work>/sc/<case>.json, runs it against fakeprov.py with
"full_wire": true, renders <work>/<case>/prompt-map.txt with sysprompt.py, and checks the case's
expectations: a wire regex must match some prompt-map line ("!" = no line may match); a file
expectation reads the run's files under <work>/<case>/kd-*/ (concatenated) the same way.
LIVE cases (LIVE below) run only when named: they go through recproxy.py to the real gateway with the
apiKey leaf of ~/.config/kimchi/config.json. Prints PASS/FAIL per case and exits non-zero on any FAIL. work = $PROBE_OUT/kimchi-prompt-map or a temp dir.

Sentinels: SP_CLI_* --append-system-prompt; SP_*APPEND_SYSTEM APPEND_SYSTEM.md (user = harness dir,
project = <proj>/.config/kimchi/harness, dotkimchi = <proj>/.kimchi); SP_*SYSTEM* SYSTEM.md /
--system-prompt; SP_*AGENTS*/CLAUDE* context files; SP_KHOOK_* .kimchi/hooks.json; SP_CCHOOK_*
.claude/settings.json; SP_EXT_BAS / SP_EXT_BPR the user extension (prompt_map_ext.ts); SP_ACP_META
_meta["kimchi.dev"].appendSystemPrompt; SP_AGENT_* custom agent bodies; SP_MEMORY_FACT a memory-import
fact; the memory notice is matched as "Persistent memory is enabled".
"""
import json, os, re, subprocess, sys, tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "common"))
import pin  # noqa: E402

EXT = (HERE / "prompt_map_ext.ts").read_text()
P = ["--model", "kimchi-dev/fake-a"]
HELLO = ["-p", "hello SP_USER_PROMPT"]


def S(name):
    """A sentinel placed in the system message."""
    return rf"{name}@sys:\d+%<[^>]*>"


def hook(path):
    return {"hooks": [{"type": "command", "command": "cat " + path}]}


def hooks_json(prefix):
    return json.dumps({"hooks": {"SessionStart": [hook(f".kimchi/{prefix}-ss.json")], "UserPromptSubmit": [hook(f".kimchi/{prefix}-ups.json")]}})


HOOKS = {
    ".kimchi/hooks.json": hooks_json("k"),
    ".kimchi/k-ss.json": json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "SP_KHOOK_SS"}}),
    ".kimchi/k-ups.json": json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit", "additionalContext": "SP_KHOOK_UPS"}}),
    ".claude/settings.json": hooks_json("c"),
    ".kimchi/c-ss.json": json.dumps({"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": "SP_CCHOOK_SS"}}),
    ".kimchi/c-ups.json": json.dumps({"systemMessage": "SP_CCHOOK_UPS_SYSMSG"}),
}
AGENTS = {
    ".kimchi/agents/rep-agent.md": "---\ndescription: replace-mode probe agent\n---\nSP_AGENT_REPLACE_BODY\n",
    ".kimchi/agents/app-agent.md": "---\ndescription: append-mode probe agent\nprompt_mode: append\n---\nSP_AGENT_APPEND_BODY\n",
}
CTX = {"AGENTS.md": "SP_PROJ_AGENTS_MD\n", "AGENTS.local.md": "SP_PROJ_AGENTS_LOCAL\n", "CLAUDE.md": "SP_PROJ_CLAUDE_MD\n"}
USER_APPEND = {".config/kimchi/harness/APPEND_SYSTEM.md": "SP_USER_APPEND_SYSTEM\n"}
HOME = {**USER_APPEND, ".config/kimchi/harness/AGENTS.md": "SP_GLOBAL_AGENTS_MD\n", ".config/kimchi/harness/extensions/spx.ts": EXT}
TRUST = {".config/kimchi/harness/trust.json": json.dumps({"@PROJ@": True})}
MEMORY = {"pre_args": [["memory-import", "--facts", "@PROJ@/facts.jsonl", "--verbatim"]],
          "env": {"KIMCHI_ENABLE_RESOURCES": "extensions.memory"}}
FACTS = {"facts.jsonl": json.dumps({"fact": "The user prefers SP_MEMORY_FACT for every probe."}) + "\n"}
WORKFLOW = ("import { createAgentStep, createWorkflow } from \"@kimchi-dev/kimchi-workflows\"\n\n"
            "const bg = createAgentStep({ name: \"bg-step\", background: true, prompt: () => \"WF_BG_STEP\" })\n"
            "const inSession = createAgentStep({ name: \"in-session-step\", prompt: () => \"WF_INSESSION_STEP\" })\n\n"
            "export default createWorkflow({ name: \"probe\", description: \"prompt-map probe\" }).then(bg).then(inSession).commit()\n")


def agent(prompt, typ, **kw):
    return {"name": "Agent", "args": {"prompt": prompt, "description": prompt.lower(), "subagent_type": typ, **kw}}


def plan(turns):
    return "go SP_USER_PROMPT PLAN=" + json.dumps(turns)


def rpc(at, msg):
    return {"at": at, "line": {"type": "prompt", "message": msg}}


ACP_INIT = {"at": 0.5, "line": {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": 1, "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False}}}}


def acp_new(meta):
    params = {"cwd": "@PROJ@", "mcpServers": []}
    if meta:
        params["_meta"] = {"kimchi.dev": {"appendSystemPrompt": meta}}
    return {"at": 1, "line": {"jsonrpc": "2.0", "id": 2, "method": "session/new", "params": params}}


def acp_prompt(at, text, rid=3):
    return {"at": at, "line": {"jsonrpc": "2.0", "id": rid, "method": "session/prompt", "params": {"sessionId": "@SID@", "prompt": [{"type": "text", "text": text}]}}}


FANOUT = [[agent("CHILD_EXPLORE", "Explore"), agent("CHILD_GP", "General-Purpose"), agent("CHILD_REP", "rep-agent"),
           agent("CHILD_APP", "app-agent"), agent("CHILD_UNKNOWN", "NoSuchType"),
           agent("CHILD_ISOLATED", "General-Purpose", isolated=True), agent("CHILD_INHERIT", "General-Purpose", inherit_context=True)]]
MAIN_FILES = S("SP_GLOBAL_AGENTS_MD") + " " + S("SP_PROJ_AGENTS_MD") + " " + S("SP_PROJ_AGENTS_LOCAL")
GP_TAIL = S("SP_PROJ_AGENTS_MD") + " " + S("SP_PROJ_AGENTS_LOCAL") + " " + S("SP_EXT_BAS") + " " + S("SP_EXT_BPR") + "$"
SS_RE = S("SP_KHOOK_SS")
WIRE_FILE = "kd-*/home/spx-load.jsonl"
DEBUG_EXPORTS = "kd-*/project/.kimchi/debug/dmu/main-agent-single-*.md"

CASES = {
    # Every channel at once from kimchi -p, plus one child of every kind.
    "p01-print-all": ({"timeout": 90, "args": P + ["--mode", "json", "--approve", "--append-system-prompt", "SP_CLI_APPEND", "-p", plan(FANOUT)],
                       "files": {**CTX, **HOOKS, **AGENTS}, "home_files": HOME}, [
        ("wire", rf"^#0 main .* sys=developer:\d+ .*\| {MAIN_FILES} {S('SP_CLI_APPEND')} {SS_RE} {S('SP_EXT_BPR')} SP_KHOOK_UPS@user\[1\] SP_USER_PROMPT@user\[2\]$"),
        ("!wire", r" main .*SP_EXT_BAS"),
        ("!wire", r"SP_USER_APPEND_SYSTEM|SP_PROJ_CLAUDE_MD|SP_CCHOOK"),
        ("wire", rf"child-replace label=CHILD_EXPLORE .*\| {S('SP_EXT_BAS')} {S('SP_EXT_BPR')}$"),
        ("wire", rf"child-replace label=CHILD_GP .*\| {GP_TAIL}"),
        ("wire", rf"child-replace label=CHILD_UNKNOWN .*\| {GP_TAIL}"),
        ("wire", rf"child-replace label=CHILD_REP .*\| SP_AGENT_REPLACE_BODY@sys:\d+%<## Available Tools> {S('SP_EXT_BAS')} {S('SP_EXT_BPR')}$"),
        ("wire", rf"child-append label=CHILD_APP .*\| {MAIN_FILES} {S('SP_CLI_APPEND')} {SS_RE} SP_AGENT_APPEND_BODY@sys:\d+%<<agent_instructions>> {S('SP_EXT_BAS')} {S('SP_EXT_BPR')}$"),
        ("wire", r"child-replace label=CHILD_ISOLATED .*\| -$"),
        ("wire", rf"child-replace label=- .*\| {S('SP_PROJ_AGENTS_MD')} .*SP_EXT_BPR@sys:\d+%<[^>]*> SP_USER_PROMPT@user\[1\]$"),
        ("wire", r"^#\d+ title .*sys=system:341 msgs=sys,use \| SP_USER_PROMPT@user\[1\]$"),
        ("file", WIRE_FILE, r'"createSystemPromptBlocks":"undefined","keys":\["parseSkillBlock"\]'),
    ]),
    # RPC: hook SessionStart text is turn-one only and returns after compaction; compaction has its own system.
    "p02-rpc-turns-compact": ({"timeout": 40, "close_stdin": False, "settings": {"compaction": {"keepRecentTokens": 1}},
                               "args": P + ["--mode", "rpc", "--approve", "--append-system-prompt", "SP_CLI_APPEND"],
                               "stdin_lines": [rpc(1.5, "first SP_TURN1"), rpc(8, "second SP_TURN2"),
                                               {"at": 14, "line": {"type": "compact", "customInstructions": "SP_COMPACT_INSTR"}}, rpc(22, "third SP_TURN3")],
                               "files": {**CTX, **HOOKS, **AGENTS}, "home_files": HOME}, [
        ("wire", rf"^#0 main .*{S('SP_CLI_APPEND')} {SS_RE} {S('SP_EXT_BPR')} SP_KHOOK_UPS@user\[1\] SP_TURN1@user\[2\]$"),
        ("wire", rf"^#2 main .*{S('SP_CLI_APPEND')} {S('SP_EXT_BPR')} .*SP_TURN2@user\[5\]$"),
        ("wire", r"^#3 compaction .*sys=developer:310 msgs=dev,use \| .*SP_COMPACT_INSTR@user\[1\]$"),
        ("!wire", r" compaction .*@sys"),
        ("wire", rf"^#5 main .*{S('SP_CLI_APPEND')} {SS_RE} {S('SP_EXT_BPR')} .*SP_TURN3@user\[3\]$"),
        ("file", "wire.jsonl", r"^.*context summarization assistant.*Prompt summary.*$"),
        ("!file", "wire.jsonl", r"^.*You are Kimchi.*Prompt summary.*$"),
    ]),
    # ACP, trusted: CLI append first, _meta second; both reach append-mode children only.
    "p03-acp-cli-meta": ({"acp": True, "timeout": 40, "close_stdin": False,
                          "args": P + ["--mode", "acp", "--append-system-prompt", "SP_CLI_APPEND"],
                          "stdin_lines": [ACP_INIT, acp_new("SP_ACP_META"),
                                          acp_prompt(3, plan([[agent("CHILD_GP", "General-Purpose"), agent("CHILD_APP", "app-agent")]])),
                                          acp_prompt(15, "second SP_TURN2", 4)],
                          "files": {**CTX, **HOOKS, **AGENTS}, "home_files": {**HOME, **TRUST}}, [
        ("wire", rf"^#0 main .*\| {MAIN_FILES} {S('SP_CLI_APPEND')} {S('SP_ACP_META')} {SS_RE} {S('SP_EXT_BPR')} SP_KHOOK_UPS@user\[1\]"),
        ("wire", rf"child-replace label=CHILD_GP .*\| {GP_TAIL}"),
        ("wire", rf"child-append label=CHILD_APP .*{S('SP_CLI_APPEND')} {S('SP_ACP_META')} {SS_RE} SP_AGENT_APPEND_BODY"),
        ("wire", rf"main label=CHILD_DONE .*{S('SP_ACP_META')} {S('SP_EXT_BPR')} .*SP_TURN2@user"),
        ("!wire", r"SP_USER_APPEND_SYSTEM"),
    ]),
    # ACP, project untrusted: the named project agent is not loaded and app-agent falls back to General-Purpose.
    "p03b-acp-untrusted-agents": ({"acp": True, "timeout": 25, "close_stdin": False,
                                   "args": P + ["--mode", "acp", "--append-system-prompt", "SP_CLI_APPEND"],
                                   "stdin_lines": [ACP_INIT, acp_new("SP_ACP_META"), acp_prompt(3, plan([[agent("CHILD_APP", "app-agent")]]))],
                                   "files": {**CTX, **AGENTS}, "home_files": HOME}, [
        ("wire", rf"child-replace label=CHILD_APP .*\| {GP_TAIL}"),
        ("!wire", r"SP_AGENT_APPEND_BODY"),
    ]),
    # ACP _meta alone replaces the discovered APPEND_SYSTEM.md.
    "p04-acp-meta-only": ({"acp": True, "timeout": 20, "close_stdin": False, "args": P + ["--mode", "acp"],
                           "stdin_lines": [ACP_INIT, acp_new("SP_ACP_META"), acp_prompt(3, "hello SP_USER_PROMPT")], "home_files": USER_APPEND}, [
        ("wire", rf"^#0 main .*\| {S('SP_ACP_META')} SP_USER_PROMPT@user\[1\]$"),
        ("!wire", r"SP_USER_APPEND_SYSTEM"),
    ]),
    # ACP never reads APPEND_SYSTEM.md, even with no flag and no _meta.
    "p05-acp-no-meta": ({"acp": True, "timeout": 20, "close_stdin": False, "args": P + ["--mode", "acp"],
                         "stdin_lines": [ACP_INIT, acp_new(None), acp_prompt(3, "hello SP_USER_PROMPT")], "home_files": USER_APPEND}, [
        ("wire", r"^#0 main .*\| SP_USER_PROMPT@user\[1\]$"),
    ]),
    "p06-append-file-user": ({"timeout": 30, "args": P + ["--mode", "json"] + HELLO, "home_files": USER_APPEND}, [
        ("wire", r"^#0 main .*\| SP_USER_APPEND_SYSTEM@sys:100%<## Environment> SP_USER_PROMPT@user\[1\]$"),
    ]),
    # Project file is <proj>/.config/kimchi/harness/APPEND_SYSTEM.md and shadows the user file when trusted.
    "p07-append-file-project-trusted": ({"timeout": 30, "args": P + ["--mode", "json", "--approve"] + HELLO,
                                         "files": {".config/kimchi/harness/APPEND_SYSTEM.md": "SP_PROJ_APPEND_SYSTEM\n", ".kimchi/APPEND_SYSTEM.md": "SP_DOTKIMCHI_APPEND_SYSTEM\n"},
                                         "home_files": USER_APPEND}, [
        ("wire", r"^#0 main .*\| SP_PROJ_APPEND_SYSTEM@sys:100%<## Environment> SP_USER_PROMPT@user\[1\]$"),
    ]),
    "p08-append-file-project-untrusted": ({"timeout": 30, "args": P + ["--mode", "json", "--no-approve"] + HELLO,
                                           "files": {".config/kimchi/harness/APPEND_SYSTEM.md": "SP_PROJ_APPEND_SYSTEM\n", ".kimchi/hooks.json": "{\"hooks\": {}}"},
                                           "home_files": USER_APPEND}, [
        ("wire", r"^#0 main .*\| SP_USER_APPEND_SYSTEM@sys:100%<## Environment> SP_USER_PROMPT@user\[1\]$"),
    ]),
    # Flag twice: both, argv order; any flag suppresses APPEND_SYSTEM.md discovery.
    "p09-append-cli-twice": ({"timeout": 30, "args": P + ["--mode", "json", "--append-system-prompt", "@PROJ@/ap1.md", "--append-system-prompt", "SP_CLI_INLINE_2"] + HELLO,
                              "files": {"ap1.md": "SP_CLI_FILE_1\n"}, "home_files": USER_APPEND}, [
        ("wire", r"^#0 main .*\| SP_CLI_FILE_1@sys:100%<## Environment> SP_CLI_INLINE_2@sys:100%<## Environment> SP_USER_PROMPT@user\[1\]$"),
    ]),
    "p10-system-flag": ({"timeout": 30, "args": P + ["--mode", "json", "--system-prompt", "SP_SYSTEM_FLAG"] + HELLO}, [
        ("wire", r"^#0 main .*\| SP_USER_PROMPT@user\[1\]$"),
    ]),
    "p11-system-files": ({"timeout": 30, "args": P + ["--mode", "json", "--approve"] + HELLO,
                          "files": {".config/kimchi/harness/SYSTEM.md": "SP_PROJ_SYSTEM_MD\n"},
                          "home_files": {".config/kimchi/harness/SYSTEM.md": "SP_USER_SYSTEM_MD\n"}}, [
        ("wire", r"^#0 main .*\| SP_USER_PROMPT@user\[1\]$"),
    ]),
    "p12-context-files": ({"timeout": 30, "args": P + ["--mode", "json"] + HELLO,
                           "files": {**CTX, "CLAUDE.local.md": "SP_PROJ_CLAUDE_LOCAL\n"},
                           "home_files": {".config/kimchi/harness/AGENTS.md": "SP_GLOBAL_AGENTS_MD\n", ".config/kimchi/harness/AGENTS.local.md": "SP_GLOBAL_AGENTS_LOCAL\n",
                                          ".config/kimchi/harness/CLAUDE.md": "SP_GLOBAL_CLAUDE_MD\n"}}, [
        ("wire", rf"^#0 main .*\| {S('SP_GLOBAL_AGENTS_MD')} {S('SP_GLOBAL_AGENTS_LOCAL')} {S('SP_PROJ_AGENTS_MD')} {S('SP_PROJ_AGENTS_LOCAL')} SP_USER_PROMPT@user\[1\]$"),
    ]),
    "p13-no-context-files": ({"timeout": 30, "args": P + ["--mode", "json", "--no-context-files"] + HELLO,
                              "files": CTX, "home_files": {".config/kimchi/harness/AGENTS.md": "SP_GLOBAL_AGENTS_MD\n"}}, [
        ("wire", rf"^#0 main .*\| {MAIN_FILES} SP_USER_PROMPT@user\[1\]$"),
    ]),
    # Workflow: the in-session step runs on the parent's prompt; the background step is a fresh process
    # that rediscovers files but gets no CLI flag and, untrusted, no project hooks.
    "p15-workflow-steps": ({"timeout": 90, "workflows": True, "env": {"KIMCHI_DEBUG_SESSION": "dmu"},
                            "args": P + ["--mode", "json", "--approve", "--append-system-prompt", "SP_CLI_APPEND", "-p", "/workflow run probe"],
                            "files": {**CTX, **HOOKS, ".kimchi/workflows/probe.workflow.ts": WORKFLOW}, "home_files": HOME}, [
        ("wire", rf"main label=WF_BG_STEP .*\| {MAIN_FILES} {S('SP_USER_APPEND_SYSTEM')} {S('SP_EXT_BPR')}$"),
        ("wire", rf"main label=WF_INSESSION_STEP .*\| {MAIN_FILES} {S('SP_CLI_APPEND')} {SS_RE} {S('SP_EXT_BPR')}$"),
        ("file", DEBUG_EXPORTS, r"SP_USER_APPEND_SYSTEM"),
        ("!file", DEBUG_EXPORTS, r"SP_KHOOK_SS|SP_EXT_BPR"),
    ]),
    # Same, with the project trusted in trust.json: the background child now runs the project hooks.
    "p15b-workflow-trusted-child": ({"timeout": 90, "workflows": True, "env": {"KIMCHI_DEBUG_SESSION": "dmu"},
                                     "args": P + ["--mode", "json", "--approve", "--append-system-prompt", "SP_CLI_APPEND", "-p", "/workflow run probe"],
                                     "files": {**CTX, **HOOKS, ".kimchi/workflows/probe.workflow.ts": WORKFLOW}, "home_files": {**HOME, **TRUST}}, [
        ("wire", rf"main label=WF_BG_STEP .*\| {MAIN_FILES} {S('SP_USER_APPEND_SYSTEM')} {SS_RE} {S('SP_EXT_BPR')} SP_KHOOK_UPS@user\[1\]$"),
        ("!wire", r"label=WF_BG_STEP .*SP_CLI_APPEND"),
    ]),
    # Claude Code hooks (adapter enabled): SessionStart and systemMessage arrive as user messages, never system.
    "p16-rpc-claude-hooks": ({"timeout": 40, "close_stdin": False, "env": {"KIMCHI_ENABLE_RESOURCES": "extensions.claude-code-hook-adapter"},
                              "args": P + ["--mode", "rpc", "--approve", "--append-system-prompt", "SP_CLI_APPEND"],
                              "stdin_lines": [rpc(1.5, "first SP_TURN1"), rpc(8, "second SP_TURN2")],
                              "files": {**CTX, **HOOKS, **AGENTS}, "home_files": HOME}, [
        ("wire", rf"^#0 main .*{SS_RE} {S('SP_EXT_BPR')} SP_CCHOOK_UPS_SYSMSG@user\[1\] SP_KHOOK_UPS@user\[2\] SP_TURN1@user\[3\] SP_CCHOOK_SS@user\[4\]$"),
        ("!wire", r"SP_CCHOOK_\w+@sys"),
    ]),
    # Memory digest + notice: after the CLI append, kept on every turn, inherited by append-mode children only.
    "p17-rpc-memory-turns": ({"timeout": 25, "close_stdin": False, **MEMORY,
                              "args": P + ["--mode", "rpc", "--approve", "--append-system-prompt", "SP_CLI_APPEND"],
                              "stdin_lines": [rpc(1.5, "first SP_TURN1"),
                                              rpc(8, "second SP_TURN2 PLAN=" + json.dumps([[], [agent("CHILD_GP", "General-Purpose"), agent("CHILD_APP", "app-agent")]]))],
                              "files": {**FACTS, **AGENTS}}, [
        ("wire", rf"^#0 main .*\| {S('SP_CLI_APPEND')} SP_MEMORY_FACT@sys:\d+%<## User memory[^>]*> Persistent memory is enabled@sys:\d+%<## Memory> SP_TURN1@user\[1\]$"),
        ("wire", r"^#2 main .*SP_MEMORY_FACT@sys.*SP_TURN2@user\[3\]$"),
        ("wire", r"child-replace label=CHILD_GP .*\| -$"),
        ("wire", r"child-append label=CHILD_APP .*SP_CLI_APPEND@sys.*SP_MEMORY_FACT@sys.*Persistent memory is enabled@sys.*SP_AGENT_APPEND_BODY"),
        ("wire", r"other:You maintain the user's persistent memory store"),
    ]),
    "p18-nonreasoning-role": ({"timeout": 30, "prov_env": {"NONREASONING": "fake-b"},
                               "args": ["--model", "kimchi-dev/fake-b", "--mode", "json", "--append-system-prompt", "SP_CLI_APPEND"] + HELLO}, [
        ("wire", r"^#0 main label=- model=fake-b sys=system:\d+ msgs=sys,use \| SP_CLI_APPEND@sys"),
    ]),
    # Background workflow child under a wrapProgram-shaped launcher: respawned from process.execPath (the ELF),
    # so the wrapper body runs once, while the env it exported is inherited.
    "p19-wrapper-execpath": ({"timeout": 90, "workflows": True, "wrapper": True,
                              "args": P + ["--mode", "json", "--approve", "-p", "/workflow run probe"],
                              "files": {".kimchi/workflows/probe.workflow.ts": WORKFLOW}, "home_files": {".config/kimchi/harness/extensions/spx.ts": EXT}}, [
        ("file", "kd-*/home/wrapper-runs.log", r"\A\d+\n\Z"),
        ("file", WIRE_FILE, r'"argv":\["/\$bunfs/root/kimchi","--mode","json"\],"execPath":"/nix/store/[^"]+-kimchi-1\.5\.1/bin/kimchi","wrapperEnv":"wrapped"'),
    ]),
    # LIVE (never in the default run; costs one short turn plus the title helper): the real gateway's wire,
    # through recproxy.py, with the operator's key. Shows the role the real catalog yields and that the
    # gateway accepts the composed prompt.
    "p20-live-wire": ({"timeout": 120, "live_upstream": "https://llm.kimchi.dev",
                       "args": ["--mode", "json", "--append-system-prompt", "SP_CLI_APPEND", "-p", "Reply with the single word OK. SP_USER_PROMPT"],
                       "files": {"AGENTS.md": "SP_PROJ_AGENTS_MD\n"}}, [
        ("wire", rf"^#0 main .*\| {S('SP_PROJ_AGENTS_MD')} {S('SP_CLI_APPEND')} SP_USER_PROMPT@user\[1\]$"),
        ("file", "provider.jsonl", r'"kind": "POST", "path": "/openai/v1/chat/completions", "status": 200'),
    ]),
}
LIVE = {"p20-live-wire"}

WRAPPER = """#!/usr/bin/env bash
set -euETo pipefail
shopt -s inherit_errexit 2>/dev/null || :
# wrapProgram-shaped launcher: log the run, export one variable, exec the real binary as $0.
printf '%s\\n' "$$" >>"$HOME/wrapper-runs.log"
export SP_WRAPPER_ENV=wrapped
exec -a "$0" @REAL@ "$@"
"""


def check(kind, lines, text, pattern):
    hit = any(re.search(pattern, ln) for ln in lines) if lines is not None else re.search(pattern, text, re.M) is not None
    return (not hit) if kind.startswith("!") else hit


def run(name, work):
    scenario, expects = CASES[name]
    scenario = {"full_wire": True, **scenario}
    env = dict(os.environ)
    if scenario.pop("wrapper", False):
        real = pin.package("kimchi") / "bin" / "kimchi"
        wbin = work / "wrapper" / "bin"
        wbin.mkdir(parents=True, exist_ok=True)
        (wbin / "kimchi").write_text(WRAPPER.replace("@REAL@", str(real)))
        (wbin / "kimchi").chmod(0o755)
        env["KIMCHI_PKG"] = str(work / "wrapper")
    sc_path = work / "sc" / f"{name}.json"
    sc_path.parent.mkdir(parents=True, exist_ok=True)
    sc_path.write_text(json.dumps(scenario, indent=1) + "\n")
    out = work / name
    subprocess.run([sys.executable, str(HERE / "drive.py"), str(sc_path), str(out)], env=env, check=True, stdout=subprocess.DEVNULL)
    pm = subprocess.run([sys.executable, str(HERE / "sysprompt.py"), str(out)], check=True, capture_output=True, text=True).stdout
    (out / "prompt-map.txt").write_text(pm)
    lines = pm.splitlines()
    failed = []
    for exp in expects:
        if exp[0] in ("wire", "!wire"):
            ok = check(exp[0], lines, None, exp[1])
        else:
            text = "".join(p.read_text() for p in sorted(out.glob(exp[1])))
            ok = check(exp[0], None, text, exp[2])
        if not ok:
            failed.append(exp)
    print(("PASS " if not failed else "FAIL ") + name + "  " + str(out / "prompt-map.txt"))
    for exp in failed:
        print("  unmet:", json.dumps(exp))
    return not failed


def main():
    names = sys.argv[1:] or [n for n in CASES if n not in LIVE]
    if names == ["--list"]:
        print("\n".join(n + ("  (LIVE)" if n in LIVE else "") for n in CASES))
        return 0
    unknown = [n for n in names if n not in CASES]
    if unknown:
        sys.exit(f"unknown case(s): {' '.join(unknown)}")
    base = os.environ.get("PROBE_OUT")
    work = Path(base) / "kimchi-prompt-map" if base else Path(tempfile.mkdtemp(prefix="delegate-probe-kimchi-prompt-map-"))
    work.mkdir(parents=True, exist_ok=True)
    results = [run(n, work) for n in names]
    print(f"work: {work}")
    return 0 if all(results) else 1


sys.exit(main())
