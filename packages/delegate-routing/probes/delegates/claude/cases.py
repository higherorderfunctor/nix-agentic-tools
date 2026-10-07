import pathlib
"""Scripted mock behaviours, one per probe case. fn(body, n, state) -> (content, stop_reason, delay_s)."""
import json, re
from harness import role, last_user_has_tool_result, tool_results, text_of, S, WORK

P = ["-p", "--model", "haiku", "--setting-sources", "project", "--strict-mcp-config", "--mcp-config",
     '{"mcpServers":{}}', "--output-format", "stream-json", "--verbose"]
TXT = lambda t: ([{"type": "text", "text": t}], "end_turn", 0)


def tu(name, inp, i=1):
    return {"type": "tool_use", "id": f"toolu_{name}_{i}", "name": name, "input": inp}


def first_user_text(body):
    for m in body.get("messages", []):
        if m.get("role") == "user":
            return json.dumps(m.get("content"))
    return ""


def has_tool(body, name):
    return any(t.get("name") == name for t in body.get("tools", []))


def save_tools(body, st, key):
    st["data"].setdefault(key, {t["name"]: t.get("input_schema") for t in body.get("tools", [])})


# ---- tool inventory -------------------------------------------------------
def f_tools(body, n, st):
    save_tools(body, st, f"tools_{role(body)}")
    return TXT("INVENTORY_DONE")


# ---- nesting depth: every agent that has the Agent tool spawns one more ----
def f_depth(body, n, st):
    m = re.findall(r"DEPTH=(\d+)", first_user_text(body))
    d = int(m[-1]) if m else 0
    st["data"].setdefault("depth_tools", {})[str(d)] = [t["name"] for t in body.get("tools", [])]
    if last_user_has_tool_result(body):
        return TXT(f"DEPTH_DONE {d}")
    if has_tool(body, "Agent") and d < 8:
        return [tu("Agent", {"description": f"depth {d+1}", "subagent_type": "general-purpose",
                             "prompt": f"DEPTH={d+1} spawn deeper", "run_in_background": False}, d)], "tool_use", 0
    return TXT(f"LEAF depth={d} no Agent tool")


# ---- concurrency: one parent message with N foreground Agent calls --------
def mk_parallel(N, bg):
    def f(body, n, st):
        r = role(body)
        if r == "main":
            if tool_results(body):
                return TXT("PAR_DONE")
            return [tu("Agent", {"description": f"par {i}", "subagent_type": "general-purpose",
                                 "prompt": f"PAR_CHILD {i}", "run_in_background": bg}, i) for i in range(N)], "tool_use", 0
        return [{"type": "text", "text": "CHILD_OK"}], "end_turn", 4
    return f


# ---- background agent: what the parent gets back and whether -p waits ------
def f_bg(body, n, st):
    r = role(body)
    if r == "main":
        trs = tool_results(body)
        st["data"].setdefault("main_tool_results", []).append(trs[-1] if trs else None)
        st["data"].setdefault("main_last_msgs", []).append(body["messages"][-1])
        if not trs:
            return [tu("Agent", {"description": "bg child", "subagent_type": "general-purpose",
                                 "prompt": "BG_CHILD please work", "run_in_background": True})], "tool_use", 0
        return TXT("MAIN_TURN_END")
    return [{"type": "text", "text": "BG_CHILD_RESULT_6612"}], "end_turn", 6


# ---- model/effort resolution on the wire ------------------------------------
def mk_model(calls):
    def f(body, n, st):
        if role(body) == "main":
            if last_user_has_tool_result(body):
                return TXT("ME_DONE")
            return [tu("Agent", c, i) for i, c in enumerate(calls)], "tool_use", 0
        return TXT("CHILD_ME_OK")
    return f


# ---- child permission prompt under -p --------------------------------------
def mk_perm(subagent_type):
    def f(body, n, st):
        r = role(body)
        if r == "main":
            if last_user_has_tool_result(body):
                st["data"]["main_tr"] = tool_results(body)[-1]
                return TXT("PERM_DONE")
            return [tu("Agent", {"description": "perm", "subagent_type": subagent_type,
                                 "prompt": "PERM_CHILD run bash", "run_in_background": False})], "tool_use", 0
        if last_user_has_tool_result(body):
            st["data"]["child_tr"] = tool_results(body)[-1]
            return TXT("CHILD_SAW_RESULT")
        return [tu("Bash", {"command": "touch PERM_PROBE_FILE && echo wrote", "description": "probe"})], "tool_use", 0
    return f


CASES = {
    "tools_default": {"fn": f_tools, "argv": P + ["--tools=default", "hello"]},
    "depth": {"fn": f_depth, "argv": P + ["--permission-mode", "bypassPermissions",
                                          "--allow-dangerously-skip-permissions", "DEPTH=0 go"], "timeout": 180},
    "parallel_fg": {"fn": mk_parallel(12, False), "argv": P + ["--permission-mode", "bypassPermissions",
                                                               "--allow-dangerously-skip-permissions", "par"], "timeout": 180},
    "parallel_bg": {"fn": mk_parallel(12, True), "argv": P + ["--permission-mode", "bypassPermissions",
                                                              "--allow-dangerously-skip-permissions", "par"], "timeout": 180},
    "bg": {"fn": f_bg, "argv": P + ["--permission-mode", "bypassPermissions",
                                    "--allow-dangerously-skip-permissions", "bg"], "timeout": 120},
    "model_effort": {"fn": mk_model([
        {"description": "inherit", "subagent_type": "general-purpose", "prompt": "ME inherit", "run_in_background": False},
        {"description": "sonnet", "subagent_type": "general-purpose", "prompt": "ME sonnet", "model": "sonnet", "run_in_background": False},
        {"description": "pinned", "subagent_type": "pinned", "prompt": "ME pinned", "run_in_background": False},
        {"description": "pinned+override", "subagent_type": "pinned", "prompt": "ME pinned override", "model": "haiku", "run_in_background": False},
    ]), "argv": P + ["--effort", "high", "--permission-mode", "bypassPermissions", "--allow-dangerously-skip-permissions", "me"]},
    "perm_default": {"fn": mk_perm("general-purpose"), "argv": P + ["perm"]},
    "perm_none": {"fn": mk_perm("general-purpose"), "argv": P + ["--permission-prompts", "none", "perm"]},
    "perm_named_bypass": {"fn": mk_perm("bypass"), "argv": P + ["perm"]},
}

# ---- env/flag variants -------------------------------------------------------
BYP = ["--permission-mode", "bypassPermissions", "--allow-dangerously-skip-permissions"]
CASES.update({
    "depth_env1": {**CASES["depth"], "env": {"CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH": "1"}},
    "tools_disable_bg": {"fn": f_tools, "argv": P + ["--tools=default", "hello"], "env": {"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1"}},
    "tools_teams": {"fn": f_tools, "argv": P + ["--tools=default", "hello"], "env": {"CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"}},
    "tools_fork": {"fn": f_tools, "argv": P + ["--tools=default", "hello"], "env": {"CLAUDE_CODE_FORK_SUBAGENT": "1"}},
    "tools_deny_agent": {"fn": f_tools, "argv": P + ["--tools=default", "--disallowedTools", "Agent", "--", "hello"]},
})

# ---- Workflow -----------------------------------------------------------------
WF_SCRIPT = r"""export const meta = { name: 'probe', description: 'offline probe workflow' }
const a = await agent('WF_NODE_A model sonnet effort low', { label: 'a', model: 'sonnet', effort: 'low' })
const b = await agent('WF_NODE_B agentType pinned', { label: 'b', agentType: 'pinned' })
const c = await agent('WF_NODE_C default try nesting', { label: 'c' })
const p = await parallel(Array.from({ length: 20 }, (_, i) => () => agent('WF_PAR ' + i, { label: 'p' + i })))
return { a, b, c, n: p.filter(Boolean).length }
"""


def mk_wf(resume=False):
    def f(body, n, st):
        r = role(body)
        fu = first_user_text(body)
        allu = text_of(body)
        if r == "main":
            trs = tool_results(body)
            st["data"].setdefault("main_last", []).append(json.dumps(body["messages"][-1])[:3000])
            if not trs:
                return [tu("Workflow", {"script": WF_SCRIPT})], "tool_use", 0
            if resume and "RESUMED" not in allu and "<task-notification>" in allu and not st["data"].get("resumed"):
                m = re.search(r"Run ID: (wf_[a-z0-9-]{6,})", allu)
                sp = re.search(r"Script file: (/[^\s\"\\]+\.js)", allu)
                st["data"]["resumed"] = True
                st["data"]["resume_args"] = {"run": m and m.group(1), "path": sp and sp.group(1)}
                return [tu("Workflow", {"scriptPath": sp.group(1), "resumeFromRunId": m.group(1)}, 2)], "tool_use", 0
            return TXT("WF_MAIN_END")
        key = re.search(r"WF_(NODE_[ABC]|PAR \d+)", fu)
        key = key.group(1) if key else "other"
        st["data"].setdefault("wf_children", {}).setdefault(key, []).append(
            {"n": n, "model": body.get("model"), "oc": body.get("output_config"),
             "tools": [t["name"] for t in body.get("tools", [])], "sys_head": json.dumps(body.get("system"))[:400]})
        if key == "NODE_C" and has_tool(body, "Agent") and not last_user_has_tool_result(body):
            return [tu("Agent", {"description": "nested", "prompt": "WF_NESTED child", "run_in_background": False})], "tool_use", 0
        return [{"type": "text", "text": f"RESULT_{key}"}], "end_turn", (2 if key.startswith("PAR") else 0)
    return f


CASES.update({
    "wf_default": {"fn": mk_wf(), "argv": P + ["wf"], "timeout": 120},
    "wf_bypass": {"fn": mk_wf(), "argv": P + BYP + ["wf"], "timeout": 180},
    "wf_bypass_cap4": {"fn": mk_wf(), "argv": P + BYP + ["wf"], "timeout": 180,
                       "env": {"CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS": "4"}},
    "wf_resume": {"fn": mk_wf(resume=True), "argv": P + BYP + ["wf"], "timeout": 240},
})
CASES["wf_allowed"] = {"fn": mk_wf(), "argv": P + ["--allowedTools", "Workflow", "--", "wf"], "timeout": 180}

# ---- lifecycle: stop / steer / continue a background agent ----------------------
def agent_id(text):
    m = re.search(r"agentId: ([a-z0-9]+)", text)
    return m and m.group(1)


def mk_stop(propagate=False):
    def f(body, n, st):
        r = role(body)
        fu = first_user_text(body)
        allu = text_of(body)
        if r == "main":
            trs = tool_results(body)
            st["data"].setdefault("main_last", []).append(json.dumps(body["messages"][-1])[:2500])
            if not trs:
                return [tu("Agent", {"description": "stoppable", "prompt": "STOP_CHILD work long",
                                     "run_in_background": True})], "tool_use", 0
            if len(trs) == 1:
                import time as _t; _t.sleep(1.5)
                return [tu("TaskStop", {"task_id": agent_id(allu)}, 2)], "tool_use", 0
            return TXT("STOP_MAIN_END")
        if "STOP_GRANDCHILD" in fu:
            return [{"type": "text", "text": "GRANDCHILD_DONE"}], "end_turn", 30
        if propagate and not last_user_has_tool_result(body):
            return [tu("Agent", {"description": "grandchild", "prompt": "STOP_GRANDCHILD long",
                                 "run_in_background": False}, 3)], "tool_use", 0
        return [{"type": "text", "text": "STOP_CHILD_DONE"}], "end_turn", 30
    return f


def f_steer(body, n, st):
    r = role(body)
    allu = text_of(body)
    if r == "main":
        trs = tool_results(body)
        st["data"].setdefault("main_last", []).append(json.dumps(body["messages"][-1])[:2500])
        if not trs:
            return [tu("Agent", {"description": "steerable", "prompt": "STEER_CHILD start",
                                 "run_in_background": True})], "tool_use", 0
        if len(trs) == 1:
            return [tu("SendMessage", {"to": agent_id(allu), "summary": "steer", "message": "STEER_MSG_77 change course"}, 2)], "tool_use", 0
        if "<task-notification>" in allu and "FOLLOWUP_88" not in allu and len(trs) == 2:
            return [tu("SendMessage", {"to": agent_id(allu), "summary": "followup", "message": "FOLLOWUP_88 one more thing"}, 3)], "tool_use", 0
        return TXT("STEER_MAIN_END")
    st["data"].setdefault("child_reqs", []).append({"n": n, "has_steer": "STEER_MSG_77" in allu,
                                                    "has_followup": "FOLLOWUP_88" in allu,
                                                    "n_msgs": len(body["messages"]),
                                                    "last": json.dumps(body["messages"][-1])[:1200]})
    if not last_user_has_tool_result(body) and "FOLLOWUP_88" not in json.dumps(body["messages"][-1]):
        return [tu("Bash", {"command": "sleep 4; echo slept", "description": "wait"}, n)], "tool_use", 0
    if "FOLLOWUP_88" in json.dumps(body["messages"][-1]):
        return TXT("CHILD_FOLLOWUP_ACK")
    return TXT("STEER_CHILD_DONE")


CASES.update({
    "stop_bg": {"fn": mk_stop(), "argv": P + BYP + ["stop"], "timeout": 120},
    "stop_bg_propagate": {"fn": mk_stop(True), "argv": P + BYP + ["stop"], "timeout": 120},
    "steer_bg": {"fn": f_steer, "argv": P + BYP + ["steer"], "timeout": 120},
})

# ---- SDK control protocol (stream-json in/out) ----------------------------------
def f_ctl(body, n, st):
    r = role(body)
    allu = text_of(body)
    if r == "main":
        turns = re.findall(r"CTL_TURN(\d)", allu)
        t = turns[-1] if turns else "0"
        last = body["messages"][-1]
        st["data"].setdefault("main", []).append({"n": n, "turn": t, "model": body.get("model"),
                                                  "oc": body.get("output_config"), "thinking": body.get("thinking")})
        msgs = body["messages"]
        li = max([i for i, m in enumerate(msgs) if "CTL_TURN" in json.dumps(m)] or [0])
        if any("tool_result" in json.dumps(m) for m in msgs[li:]):
            return TXT(f"CTL_MAIN_DONE_{t}")
        spec = {"1": ("CTL_CHILD1_LONG", None), "2": ("CTL_CHILD2_SHORT", None), "3": ("CTL_CHILD3_LONG", None)}.get(t)
        if not spec:
            return TXT("CTL_NOOP")
        return [tu("Agent", {"description": f"ctl {t}", "prompt": spec[0], "run_in_background": False}, n)], "tool_use", 0
    fu = first_user_text(body)
    st["data"].setdefault("child", []).append({"n": n, "model": body.get("model"), "oc": body.get("output_config"),
                                               "which": re.findall(r"CTL_CHILD\d_\w+", fu)[:1]})
    return [{"type": "text", "text": "CTL_CHILD_OK"}], "end_turn", (25 if "LONG" in fu else 0)


def ctl_driver(argv, cwd, env, out):
    import subprocess, threading, time, json as J
    p = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True, bufsize=1)
    events, lock = [], threading.Lock()
    def rd():
        for line in p.stdout:
            try:
                ev = J.loads(line)
            except Exception:
                ev = {"raw": line}
            ev["_t"] = time.time()
            with lock:
                events.append(ev)
    threading.Thread(target=rd, daemon=True).start()
    log = []
    def send(o):
        log.append({"t": time.time(), "sent": o}); p.stdin.write(J.dumps(o) + "\n"); p.stdin.flush()
    def wait(pred, to=40):
        end = time.time() + to
        while time.time() < end:
            with lock:
                for e in events:
                    if pred(e) and not e.get("_seen"):
                        e["_seen"] = True
                        return e
            time.sleep(0.1)
        return None
    def user(text):
        send({"type": "user", "message": {"role": "user", "content": text}, "parent_tool_use_id": None, "session_id": ""})
    send({"type": "control_request", "request_id": "init1", "request": {"subtype": "initialize"}})
    wait(lambda e: e.get("type") == "control_response")
    # turn 1: stop_task on a FOREGROUND agent
    user("CTL_TURN1")
    ts = wait(lambda e: e.get("subtype") == "task_started")
    time.sleep(1.5)
    send({"type": "control_request", "request_id": "stop1", "request": {"subtype": "stop_task", "task_id": ts and ts["task_id"]}})
    log.append({"resp_stop": wait(lambda e: e.get("type") == "control_response" and e.get("response", {}).get("request_id") == "stop1")})
    log.append({"result1": wait(lambda e: e.get("type") == "result")})
    # unsupported? send_task_message
    send({"type": "control_request", "request_id": "stm1", "request": {"subtype": "send_task_message", "task_id": ts and ts["task_id"], "message": "X"}})
    log.append({"resp_stm": wait(lambda e: e.get("type") == "control_response" and e.get("response", {}).get("request_id") == "stm1", 8)})
    # turn 2: set_model then a child with no model
    send({"type": "control_request", "request_id": "sm1", "request": {"subtype": "set_model", "model": "sonnet"}})
    log.append({"resp_set_model": wait(lambda e: e.get("type") == "control_response" and e.get("response", {}).get("request_id") == "sm1")})
    user("CTL_TURN2")
    log.append({"result2": wait(lambda e: e.get("type") == "result")})
    # turn 3: interrupt during a foreground child
    user("CTL_TURN3")
    wait(lambda e: e.get("subtype") == "task_started")
    time.sleep(1.5)
    send({"type": "control_request", "request_id": "int1", "request": {"subtype": "interrupt"}})
    log.append({"resp_int": wait(lambda e: e.get("type") == "control_response" and e.get("response", {}).get("request_id") == "int1")})
    log.append({"result3": wait(lambda e: e.get("type") == "result")})
    p.stdin.close()
    try:
        p.wait(20)
    except Exception:
        p.kill()
        p.wait()
    (out / "driver-log.json").write_text(J.dumps(log, indent=1, default=str))
    with lock:
        so = "\n".join(J.dumps(e) for e in events)
    return p.returncode, so, p.stderr.read()


CASES["ctl"] = {"fn": f_ctl, "driver": ctl_driver,
                "argv": ["-p", "--model", "haiku", "--effort", "high", "--setting-sources", "project", "--strict-mcp-config",
                         "--mcp-config", '{"mcpServers":{}}', "--input-format", "stream-json", "--output-format", "stream-json",
                         "--verbose"] + BYP}

# ---- hooks gating sub-agents ------------------------------------------------------
HK = str(S / "hook.sh")


def hooks_settings(logdir, start_resp=None, stop_resp=None, pre_resp=None):
    def h(ev, resp=None, matcher=None):
        cmd = f"{HK} {logdir} {ev}" + (f" {resp}" if resp else "")
        e = {"hooks": [{"type": "command", "command": cmd}]}
        if matcher:
            e["matcher"] = matcher
        return [e]
    return json.dumps({"hooks": {
        "SubagentStart": h("SubagentStart", start_resp),
        "SubagentStop": h("SubagentStop", stop_resp),
        "PreToolUse": h("PreToolUse", pre_resp, "Agent"),
        "PostToolUse": h("PostToolUse", None, "Agent"),
        "TaskCreated": h("TaskCreated"), "TaskCompleted": h("TaskCompleted")}})


def f_hooks(body, n, st):
    r = role(body)
    allu = text_of(body)
    if r == "main":
        if tool_results(body):
            st["data"]["main_tr"] = json.dumps(tool_results(body)[-1])[:1500]
            return TXT("HOOK_MAIN_DONE")
        return [tu("Agent", {"description": "hooked", "prompt": "HOOK_CHILD", "run_in_background": False})], "tool_use", 0
    st["data"].setdefault("child", []).append({"n": n, "ctx_has_START_CTX": "START_CTX_31" in allu,
                                               "has_KEEP": "KEEP_GOING_42" in allu, "nmsg": len(body["messages"])})
    return TXT("HOOK_CHILD_DONE")


def hook_case(name, **resp):
    logdir = WORK / "out" / name / "hooks"
    files = {}
    for k, v in resp.items():
        f = WORK / "fixture-hook-resp" / f"{name}-{k}.json"
        files[k] = f
    def prep():
        (WORK / "fixture-hook-resp").mkdir(exist_ok=True)
        for k, v in resp.items():
            files[k].write_text(json.dumps(v))
    return {"fn": f_hooks, "prep": prep,
            "argv": P + BYP + ["--settings", hooks_settings(logdir, **{k: str(files[k]) for k in files}), "hooks"]}


CASES.update({
    "hooks_obs": hook_case("hooks_obs", start_resp={"hookSpecificOutput": {"hookEventName": "SubagentStart",
                                                                           "additionalContext": "START_CTX_31"}}),
    "hooks_block": hook_case("hooks_block", stop_resp={"decision": "block", "reason": "KEEP_GOING_42"}),
    "hooks_deny": hook_case("hooks_deny", pre_resp={"hookSpecificOutput": {"hookEventName": "PreToolUse",
                                                                           "permissionDecision": "deny",
                                                                           "permissionDecisionReason": "DENY_AGENT_55"}}),
})

CASES["hooks_rewrite"] = hook_case("hooks_rewrite", pre_resp={"hookSpecificOutput": {
    "hookEventName": "PreToolUse", "permissionDecision": "allow",
    "updatedInput": {"description": "hooked", "prompt": "HOOK_CHILD rewritten", "run_in_background": False,
                     "model": "sonnet", "subagent_type": "general-purpose"}}})
_wfh = hook_case("hooks_wf")
CASES["hooks_wf"] = {"fn": mk_wf(), "prep": _wfh["prep"], "timeout": 180,
                     "argv": P + BYP + ["--settings", hooks_settings(WORK / "out" / "hooks_wf" / "hooks"), "wf"]}

# ---- isolation / frontmatter background / maxTurns ---------------------------------------
def mk_iso(call, child_cmd="pwd; git rev-parse --abbrev-ref HEAD; touch WT_FILE_19; echo made"):
    def f(body, n, st):
        r = role(body)
        if r == "main":
            trs = tool_results(body)
            st["data"].setdefault("main_last", []).append(json.dumps(body["messages"][-1])[:1800])
            if not trs:
                return [tu("Agent", call)], "tool_use", 0
            return TXT("ISO_MAIN_DONE")
        m = re.search(r"Primary working directory: ([^\\]+)", text_of(body))
        st["data"].setdefault("child_cwd", []).append(m and m.group(1))
        if last_user_has_tool_result(body):
            st["data"].setdefault("child_tr", []).append(json.dumps(tool_results(body)[-1]["content"])[:400])
            return TXT("ISO_CHILD_DONE")
        return [tu("Bash", {"command": child_cmd, "description": "probe"}, n)], "tool_use", 0
    return f


def f_turns(body, n, st):
    if role(body) == "main":
        if tool_results(body):
            st["data"]["main_tr"] = json.dumps(tool_results(body)[-1])[:1500]
            return TXT("T_MAIN_DONE")
        return [tu("Agent", {"description": "turns", "subagent_type": "turns", "prompt": "TURNS_CHILD", "run_in_background": False})], "tool_use", 0
    st["data"]["child_calls"] = st["data"].get("child_calls", 0) + 1
    return [tu("Bash", {"command": "echo again", "description": "loop"}, n)], "tool_use", 0


CASES.update({
    "iso_worktree": {"fn": mk_iso({"description": "iso", "prompt": "ISO_CHILD", "isolation": "worktree", "run_in_background": False}),
                     "argv": P + BYP + ["iso"]},
    "iso_worktree_clean": {"fn": mk_iso({"description": "iso", "prompt": "ISO_CHILD", "isolation": "worktree", "run_in_background": False}, "pwd"),
                           "argv": P + BYP + ["iso"]},
    "fm_turns": {"fn": f_turns, "argv": P + BYP + ["turns"]},
})

def f_bg_long(body, n, st):
    if role(body) == "main":
        st["data"].setdefault("main_last", []).append(json.dumps(body["messages"][-1])[:1500])
        if not tool_results(body) and "<task-notification>" not in text_of(body):
            return [tu("Agent", {"description": "long bg", "prompt": "LONG_BG", "run_in_background": True})], "tool_use", 0
        return TXT("LBG_MAIN_DONE")
    return [{"type": "text", "text": "LONG_BG_DONE"}], "end_turn", 20


CASES.update({
    "bg_stall": {"fn": f_bg_long, "argv": P + BYP + ["x"], "env": {"CLAUDE_ASYNC_AGENT_STALL_TIMEOUT_MS": "3000"}, "timeout": 60},
    "bg_print_ceiling": {"fn": f_bg_long, "argv": P + BYP + ["x"], "env": {"CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS": "3000"}, "timeout": 60},
})

# ---- main-session resume / continue / fork ------------------------------------------------
def f_echo(body, n, st):
    md = json.loads(body.get("metadata", {}).get("user_id", "{}")).get("session_id")
    st["data"].setdefault("reqs", []).append({"n": n, "session": md, "nmsgs": len(body["messages"]),
                                              "markers": re.findall(r"RES_MARK_\d", text_of(body))})
    return TXT("ECHO_OK")


def resume_driver(argv, cwd, env, out):
    import subprocess, json as J
    base = argv[:argv.index("--debug-file")]
    sid = "11111111-2222-4333-8444-555555555555"
    runs = [["--session-id", sid, "RES_MARK_1"], ["--resume", sid, "RES_MARK_2"],
            ["--resume", sid, "--fork-session", "RES_MARK_3"], ["--continue", "RES_MARK_4"]]
    log = []
    for r in runs:
        p = subprocess.run(base + r, cwd=cwd, env=env, capture_output=True, text=True, timeout=60, input="")
        inits = [J.loads(l) for l in p.stdout.splitlines() if '"subtype":"init"' in l]
        log.append({"args": r, "rc": p.returncode, "init_session": inits and inits[0].get("session_id")})
    (out / "driver-log.json").write_text(J.dumps(log, indent=1))
    return 0, J.dumps(log), ""


CASES["resume_fork"] = {"fn": f_echo, "driver": resume_driver, "argv": P + BYP}

# ---- `claude mcp serve`: call the Agent tool over MCP ----------------------------------------
def f_mcpchild(body, n, st):
    st["data"].setdefault("reqs", []).append({"n": n, "role": role(body), "model": body.get("model"),
                                              "oc": body.get("output_config"),
                                              "tools": [t["name"] for t in body.get("tools", [])]})
    return TXT("MCP_CHILD_RESULT_23")


def mcp_driver(argv, cwd, env, out):
    import subprocess, json as J
    p = subprocess.Popen([argv[0], "mcp", "serve"], cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True)
    def rpc(i, m, params=None):
        p.stdin.write(J.dumps({"jsonrpc": "2.0", "id": i, "method": m, "params": params or {}}) + "\n"); p.stdin.flush()
        while True:
            line = p.stdout.readline()
            if not line:
                return None
            d = J.loads(line)
            if d.get("id") == i:
                return d
    rpc(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "probe", "version": "0"}})
    p.stdin.write(J.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); p.stdin.flush()
    r1 = rpc(2, "tools/call", {"name": "Agent", "arguments": {"description": "mcp", "prompt": "MCP_CHILD", "model": "sonnet",
                                                               "run_in_background": False}})
    r2 = rpc(3, "tools/call", {"name": "Agent", "arguments": {"description": "mcp bg", "prompt": "MCP_CHILD_BG"}})
    p.kill()
    log = {"fg": r1, "bg_default": r2}
    (out / "driver-log.json").write_text(J.dumps(log, indent=1))
    return 0, J.dumps(log)[:4000], p.stderr.read()[-2000:]


CASES["mcp_serve_agent"] = {"fn": f_mcpchild, "driver": mcp_driver, "argv": []}


def mcp_wf_driver(argv, cwd, env, out):
    import subprocess, json as J, time
    p = subprocess.Popen([argv[0], "mcp", "serve"], cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True)
    def rpc(i, m, params=None):
        p.stdin.write(J.dumps({"jsonrpc": "2.0", "id": i, "method": m, "params": params or {}}) + "\n"); p.stdin.flush()
        while True:
            line = p.stdout.readline()
            if not line:
                return None
            d = J.loads(line)
            if d.get("id") == i:
                return d
    rpc(1, "initialize", {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "probe", "version": "0"}})
    p.stdin.write(J.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"); p.stdin.flush()
    script = "export const meta = { name: 'm', description: 'mcp wf' }\nconst a = await agent('MCP_WF_NODE', { model: 'haiku' })\nreturn a\n"
    r1 = rpc(2, "tools/call", {"name": "Workflow", "arguments": {"script": script}})
    time.sleep(3)
    p.kill()
    log = {"wf": r1}
    (out / "driver-log.json").write_text(J.dumps(log, indent=1))
    return 0, J.dumps(log)[:4000], p.stderr.read()[-2000:]


CASES["mcp_serve_wf"] = {"fn": f_mcpchild, "driver": mcp_wf_driver, "argv": []}


def ctl2_driver(argv, cwd, env, out):
    import subprocess, threading, time, json as J
    p = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
    events, lock = [], threading.Lock()
    def rd():
        for line in p.stdout:
            try: ev = J.loads(line)
            except Exception: ev = {"raw": line}
            with lock: events.append(ev)
    threading.Thread(target=rd, daemon=True).start()
    def send(o): p.stdin.write(J.dumps(o) + "\n"); p.stdin.flush()
    def wait(pred, to=30):
        end = time.time() + to
        while time.time() < end:
            with lock:
                for e in events:
                    if pred(e) and not e.get("_seen"):
                        e["_seen"] = True; return e
            time.sleep(0.1)
    def user(t): send({"type": "user", "message": {"role": "user", "content": t}, "parent_tool_use_id": None, "session_id": ""})
    log = []
    send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}}); wait(lambda e: e.get("type") == "control_response")
    user("CTL_TURN2"); log.append({"r_a": bool(wait(lambda e: e.get("type") == "result"))})
    send({"type": "control_request", "request_id": "af", "request": {"subtype": "apply_flag_settings", "settings": {"effortLevel": "low"}}})
    log.append({"resp_apply": wait(lambda e: e.get("type") == "control_response" and e["response"].get("request_id") == "af")})
    user("CTL_TURN2 again"); log.append({"r_b": bool(wait(lambda e: e.get("type") == "result"))})
    send({"type": "control_request", "request_id": "pm", "request": {"subtype": "set_permission_mode", "mode": "plan"}})
    log.append({"resp_pm": wait(lambda e: e.get("type") == "control_response" and e["response"].get("request_id") == "pm")})
    (out / "driver-log.json").write_text(J.dumps(log, indent=1, default=str))
    p.stdin.close()
    try:
        p.wait(10)
    except Exception:
        p.kill()
        p.wait()
    return p.returncode, "\n".join(J.dumps(e) for e in events), p.stderr.read()


CASES["ctl_effort"] = {"fn": f_ctl, "driver": ctl2_driver,
                       "argv": ["-p", "--model", "sonnet", "--effort", "high", "--setting-sources", "project", "--strict-mcp-config",
                                "--mcp-config", '{"mcpServers":{}}', "--input-format", "stream-json", "--output-format", "stream-json",
                                "--verbose"] + BYP}

# ---- workflow: TaskStop propagation, budget, saved/named workflow ------------------------
WF_LONG = r"""export const meta = { name: 'long', description: 'long probe workflow' }
const r = await parallel([0, 1, 2].map(i => () => agent('WFL_NODE ' + i, { label: 'l' + i })))
return r
"""
WF_BUDGET = r"""export const meta = { name: 'bud', description: 'budget probe' }
const t = budget.total
const s = await workflow('saved', { x: 'SAVEDARG' })
return { total: t, remaining: budget.remaining(), saved: s }
"""


def f_wf_stop(body, n, st):
    if role(body) == "main":
        trs = tool_results(body)
        allu = text_of(body)
        st["data"].setdefault("main_last", []).append(json.dumps(body["messages"][-1])[:1500])
        if not trs:
            return [tu("Workflow", {"script": WF_LONG})], "tool_use", 0
        if len(trs) == 1:
            import time as _t; _t.sleep(2)
            m = re.search(r"Task ID: (\w+)", allu)
            return [tu("TaskStop", {"task_id": m.group(1)}, 2)], "tool_use", 0
        return TXT("WFS_MAIN_DONE")
    return [{"type": "text", "text": "WFL_DONE"}], "end_turn", 30


def f_wf_budget(body, n, st):
    if role(body) == "main":
        trs = tool_results(body)
        st["data"].setdefault("main_last", []).append(json.dumps(body["messages"][-1])[:2500])
        if not trs:
            return [tu("Workflow", {"script": WF_BUDGET})], "tool_use", 0
        return TXT("WFB_MAIN_DONE")
    st["data"].setdefault("child_first_user", []).append(re.findall(r"SAVED_NODE \w+", first_user_text(body)))
    return TXT("WFB_NODE_DONE")


CASES.update({
    "wf_stop": {"fn": f_wf_stop, "argv": P + BYP + ["wf"], "timeout": 120},
    "wf_budget": {"fn": f_wf_budget, "argv": P + BYP + ["+50k use a workflow"], "timeout": 120},
})
CASES["depth_settings_env1"] = {**CASES["depth"], "argv": P + BYP + ["--settings", '{"env":{"CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH":"1","CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS":"3"}}', "DEPTH=0 go"]}
CASES["parallel_settings_cap3"] = {**CASES["parallel_fg"], "argv": P + BYP + ["--settings", '{"env":{"CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS":"3"}}', "par"]}
CASES["tools_settings_disablewf"] = {"fn": f_tools, "argv": P + ["--tools=default", "--settings", '{"disableWorkflows":true}', "hello"]}
CASES["agents_json"] = {"fn": mk_model([
    {"description": "j", "subagent_type": "jsonagent", "prompt": "ME json", "run_in_background": False}]),
    "argv": P + BYP + ["--agents", '{"jsonagent":{"description":"json agent","prompt":"JSON_BODY_61","model":"sonnet","effort":"low","tools":["Read"]}}', "--", "me"]}
CASES["model_force"] = {**CASES["model_effort"], "env": {"CLAUDE_CODE_SUBAGENT_MODEL": "sonnet", "CLAUDE_CODE_SUBAGENT_MODEL_FORCE": "1"}}
CASES["wf_force"] = {**CASES["wf_bypass"], "env": {"CLAUDE_CODE_SUBAGENT_MODEL": "haiku", "CLAUDE_CODE_SUBAGENT_MODEL_FORCE": "1"}}
CASES["agents_nobuiltin"] = {"fn": f_tools, "argv": P + ["--tools=default", "hello"], "env": {"CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS": "1"}}
CASES["agents_noexplore"] = {"fn": f_tools, "argv": P + ["--tools=default", "hello"], "env": {"CLAUDE_CODE_DISABLE_EXPLORE_PLAN_AGENTS": "1"}}


def f_perm_write(body, n, st):
    r = role(body)
    if r == "main":
        if tool_results(body):
            return TXT("PW_DONE")
        return [tu("Agent", {"description": "pw", "subagent_type": st.get("pw_type", "accept"), "prompt": "PW_CHILD", "run_in_background": False})], "tool_use", 0
    if last_user_has_tool_result(body):
        st["data"]["child_tr"] = tool_results(body)[-1]
        return TXT("PW_CHILD_DONE")
    return [tu("Write", {"file_path": str(WORK / "fixture" / "PW_FILE.txt"), "content": "x"})], "tool_use", 0


CASES["perm_named_accept"] = {"fn": f_perm_write, "argv": P + ["perm"]}





# ---- JUDGE additions ---------------------------------------------------------
# default concurrent-subagent cap (no env): 22 foreground calls in one turn
CASES["judge_parallel_fg22"] = {"fn": mk_parallel(22, False), "argv": P + BYP + ["par"], "timeout": 240}

# can the main session SendMessage a RUNNING workflow node? (codex-side: maybe; claude-side: no)
WF_MSG = r"""export const meta = { name: 'msg', description: 'node messaging probe' }
const r = await agent('WFM_NODE work', { label: 'nodeA' })
return r
"""
def f_judge_wf_msg(body, n, st):
    allu = text_of(body)
    if role(body) == "main":
        trs = tool_results(body)
        st["data"].setdefault("main_trs", []).append([json.dumps(t.get("content"))[:800] for t in trs[len(st["data"].get("seen", [])):]])
        st["data"]["seen"] = trs
        if not trs:
            return [tu("Workflow", {"script": WF_MSG})], "tool_use", 0
        if len(trs) == 1:
            import time as _t; _t.sleep(2)
            return [tu("ListAgents", {}, 2)], "tool_use", 0
        if len(trs) == 2:
            tid = re.search(r"Task ID: (\w+)", allu)
            import glob as _g
            _base = str(WORK / "cfg" / "judge_wf_msg")
            ids = [pathlib.Path(f).name[len("agent-"):-len(".jsonl")] for f in _g.glob(_base + "/projects/*/*/subagents/workflows/*/agent-*.jsonl")]
            st["data"]["listed_ids"] = ids
            calls = [tu("SendMessage", {"to": tid.group(1) if tid else "x", "summary": "to task", "message": "WFMSG_TASK_91 hello"}, 3),
                     tu("SendMessage", {"to": "nodeA", "summary": "to label", "message": "WFMSG_LABEL_92 hello"}, 4)]
            if ids:
                calls.append(tu("SendMessage", {"to": ids[0], "summary": "to listed", "message": "WFMSG_LISTED_93 hello"}, 5))
            return calls, "tool_use", 0
        return TXT("WFM_MAIN_DONE")
    st["data"].setdefault("node_reqs", []).append({"n": n, "task": "WFMSG_TASK_91" in allu, "label": "WFMSG_LABEL_92" in allu,
                                                   "listed": "WFMSG_LISTED_93" in allu, "nmsgs": len(body["messages"])})
    if not last_user_has_tool_result(body):
        return [tu("Bash", {"command": "sleep 8; echo slept", "description": "wait"}, n)], "tool_use", 0
    return TXT("WFM_NODE_DONE")

CASES["judge_wf_msg"] = {"fn": f_judge_wf_msg, "argv": P + BYP + ["wf"], "timeout": 150}

# CLAUDE_CODE_EFFORT_LEVEL vs --effort high and vs frontmatter effort:low (both sides had grep only)
CASES["judge_effort_env"] = {**CASES["model_effort"], "env": {"CLAUDE_CODE_EFFORT_LEVEL": "medium"}}

# ---- delegate-map unknowns (claude-delegate lane) -----------------------------
import cases_dmu  # noqa: E402

CASES.update(cases_dmu.CASES)

# ---- delegate-map unknowns, round 2 (--bg limits, agent teams) -----------------
import cases_dmu2  # noqa: E402

CASES.update(cases_dmu2.CASES)
