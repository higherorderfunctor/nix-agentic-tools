"""Delegate-map unknown cases (claude-delegate lane). Registered into cases.CASES.

Each case runs the pinned binary against the harness mock: `python3 harness.py <case>`.
Every mock request is also recorded in summary.json `data.reqs` (kind, model, effort, tools,
system/first-user heads) so a runner can grep one field.
"""
import json
import re
import time

from harness import WORK, S, role, text_of, tool_results


def last_user_has_tool_result(body):
    """Like harness's, but skips trailing `system` role messages (2.1.292 appends a
    `<total_tokens>` system message after a tool result on some requests)."""
    msgs = [m for m in body.get("messages", []) if m.get("role") != "system"]
    if not msgs:
        return False
    c = msgs[-1].get("content")
    return msgs[-1].get("role") == "user" and isinstance(c, list) and any(
        isinstance(x, dict) and x.get("type") == "tool_result" for x in c)

P = ["-p", "--model", "haiku", "--setting-sources", "project", "--strict-mcp-config", "--mcp-config",
     '{"mcpServers":{}}', "--output-format", "stream-json", "--verbose"]
PS = ["-p", "--model", "sonnet", "--effort", "high", "--setting-sources", "project", "--strict-mcp-config",
      "--mcp-config", '{"mcpServers":{}}', "--output-format", "stream-json", "--verbose"]
SDK = PS + ["--input-format", "stream-json"]
BYP = ["--permission-mode", "bypassPermissions", "--allow-dangerously-skip-permissions"]
TXT = lambda t: ([{"type": "text", "text": t}], "end_turn", 0)


def tu(name, inp, i=1):
    return {"type": "tool_use", "id": f"toolu_{name}_{i}", "name": name, "input": inp}


def first_user_text(body):
    for m in body.get("messages", []):
        if m.get("role") == "user":
            return json.dumps(m.get("content"))
    return ""


def sys_text(body):
    s = body.get("system")
    if isinstance(s, list):
        return " ".join(x.get("text", "") for x in s if isinstance(x, dict))
    return s or ""


def kind(body):
    """Finer request classification than harness.role()."""
    st = sys_text(body)
    if "verifying a stop condition" in st or "You are evaluating a" in st and "hook in Claude Code" in st:
        return "hook_agent"
    return role(body)


def record(body, n, st, **extra):
    st["data"].setdefault("reqs", []).append({
        "n": n, "kind": kind(body), "model": body.get("model"),
        "effort": (body.get("output_config") or {}).get("effort"),
        "tools": [t.get("name") for t in body.get("tools", [])],
        "sys_head": sys_text(body)[:160], "user_head": first_user_text(body)[:200],
        "last": json.dumps(body.get("messages", [{}])[-1])[:300], **extra})


def ctl_session(argv, cwd, env):
    """Start a stream-json session; returns (proc, send, wait, user, events)."""
    import subprocess
    import threading
    p = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True, bufsize=1)
    events, lock = [], threading.Lock()

    def rd():
        for line in p.stdout:
            try:
                ev = json.loads(line)
            except Exception:
                ev = {"raw": line}
            ev["_t"] = time.time()
            with lock:
                events.append(ev)
    threading.Thread(target=rd, daemon=True).start()

    def send(o):
        p.stdin.write(json.dumps(o) + "\n")
        p.stdin.flush()

    def wait(pred, to=40):
        end = time.time() + to
        while time.time() < end:
            with lock:
                for e in events:
                    if not e.get("_seen") and pred(e):
                        e["_seen"] = True
                        return e
            time.sleep(0.1)
        return None

    def user(text):
        send({"type": "user", "message": {"role": "user", "content": text}, "parent_tool_use_id": None,
              "session_id": ""})
    return p, send, wait, user, events, lock


def ctl_finish(p, out, log, events, lock):
    (out / "driver-log.json").write_text(json.dumps(log, indent=1, default=str))
    p.stdin.close()
    try:
        p.wait(20)
    except Exception:
        p.kill()
        p.wait()
    with lock:
        so = "\n".join(json.dumps(e) for e in events)
    return p.returncode, so, p.stderr.read()


def resp(rid):
    return lambda e: e.get("type") == "control_response" and e.get("response", {}).get("request_id") == rid


# ---- 1. running child after set_model / apply_flag_settings --------------------------------
def mk_running_switch(bg):
    def f(body, n, st):
        k = kind(body)
        allu = text_of(body)
        if k == "main":
            turn = (re.findall(r"RUN_TURN(\d)", allu) or ["0"])[-1]
            record(body, n, st, turn=turn)
            msgs = body["messages"]
            li = max([i for i, m in enumerate(msgs) if f"RUN_TURN{turn}" in json.dumps(m)] or [0])
            if any("tool_result" in json.dumps(m) for m in msgs[li:]) or "<task-notification>" in json.dumps(msgs[li:]):
                return TXT(f"RUN_MAIN_DONE_{turn}")
            return [tu("Agent", {"description": f"run {turn}", "subagent_type": "general-purpose",
                                 "prompt": f"RUN_CHILD_T{turn}", "run_in_background": bg}, n)], "tool_use", 0
        which = (re.findall(r"RUN_CHILD_T\d", first_user_text(body)) or ["?"])[0]
        step = 2 if last_user_has_tool_result(body) else 1
        record(body, n, st, child=which, step=step)
        if step == 1 and which == "RUN_CHILD_T1":
            return [tu("Bash", {"command": "sleep 6; echo slept", "description": "wait"}, n)], "tool_use", 0
        return TXT(f"RUN_CHILD_DONE {which}")
    return f


def running_switch_driver(argv, cwd, env, out):
    p, send, wait, user, events, lock = ctl_session(argv, cwd, env)
    log = []
    send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}})
    wait(resp("i"))
    user("RUN_TURN1")
    ts = wait(lambda e: e.get("subtype") == "task_started")
    log.append({"task_started": bool(ts)})
    time.sleep(2.0)  # child is inside its 6 s Bash call
    send({"type": "control_request", "request_id": "sm", "request": {"subtype": "set_model", "model": "opus"}})
    log.append({"resp_set_model": wait(resp("sm"))})
    send({"type": "control_request", "request_id": "af",
          "request": {"subtype": "apply_flag_settings", "settings": {"effortLevel": "low"}}})
    log.append({"resp_apply": wait(resp("af"))})
    log.append({"switched_at": time.time()})
    log.append({"result1": bool(wait(lambda e: e.get("type") == "result", 60))})
    user("RUN_TURN2")
    log.append({"result2": bool(wait(lambda e: e.get("type") == "result", 60))})
    return ctl_finish(p, out, log, events, lock)


CASES = {
    "dmu_running_switch_fg": {"fn": mk_running_switch(False), "driver": running_switch_driver, "argv": SDK + BYP,
                              "timeout": 150},
    "dmu_running_switch_bg": {"fn": mk_running_switch(True), "driver": running_switch_driver, "argv": SDK + BYP,
                              "timeout": 150},
}

# ---- 2. workflow node effort vs CLAUDE_CODE_EFFORT_LEVEL ------------------------------------
WF_EFFORT = r"""export const meta = { name: 'eff', description: 'node effort probe' }
const a = await agent('WFE_NODE_LOW', { label: 'low', model: 'sonnet', effort: 'low' })
const b = await agent('WFE_NODE_NONE', { label: 'none', model: 'sonnet' })
const c = await agent('WFE_NODE_PINNED', { label: 'pinned', agentType: 'pinned' })
return { a, b, c }
"""


def f_wf_effort(body, n, st):
    if kind(body) == "main":
        record(body, n, st)
        if not tool_results(body):
            return [tu("Workflow", {"script": WF_EFFORT})], "tool_use", 0
        return TXT("WFE_MAIN_DONE")
    node = (re.findall(r"WFE_NODE_\w+", first_user_text(body)) or ["?"])[0]
    record(body, n, st, node=node)
    return TXT(f"RESULT_{node}")


CASES.update({
    "dmu_wf_effort": {"fn": f_wf_effort, "argv": PS + BYP + ["wf"], "timeout": 120},
    "dmu_wf_effort_env": {"fn": f_wf_effort, "argv": PS + BYP + ["wf"], "timeout": 120,
                          "env": {"CLAUDE_CODE_EFFORT_LEVEL": "medium"}},
})


# ---- 3. frontmatter bypassPermissions: cause ------------------------------------------------
def mk_perm(subagent_type):
    def f(body, n, st):
        if kind(body) == "main":
            record(body, n, st)
            if last_user_has_tool_result(body):
                return TXT("PERM_DONE")
            return [tu("Agent", {"description": "perm", "subagent_type": subagent_type,
                                 "prompt": "PERM_CHILD run bash", "run_in_background": False})], "tool_use", 0
        if last_user_has_tool_result(body):
            st["data"]["child_tr"] = tool_results(body)[-1]
            record(body, n, st)
            return TXT("CHILD_SAW_RESULT")
        record(body, n, st)
        return [tu("Bash", {"command": "python3 -c 'open(\"DMU_BYPASS_FILE\",\"w\")' && echo BYPASS_RAN_8181", "description": "probe"})], "tool_use", 0
    return f


CASES.update({
    "dmu_bypass_default": {"fn": mk_perm("bypass"), "argv": P + ["perm"]},
    "dmu_bypass_accept": {"fn": mk_perm("bypass"), "argv": P + ["--permission-mode", "acceptEdits", "perm"]},
    "dmu_bypass_parent_bypass": {"fn": mk_perm("bypass"), "argv": P + BYP + ["perm"]},
    "dmu_bypass_policy_off": {"fn": mk_perm("bypass"), "argv": P + BYP + [
        "--settings", '{"permissions":{"disableBypassPermissionsMode":"disable"}}', "perm"]},
})

# ---- 4. workflow node stallMs, total deadline, budget.total from the SDK --------------------
WF_STALL = r"""export const meta = { name: 'stall', description: 'stall probe' }
const a = await agent('WFS_STALL_NODE', { label: 'stall', stallMs: 2000 })
return { a }
"""
WF_DEADLINE = r"""export const meta = { name: 'deadline', description: 'script-built deadline probe' }
const slow = agent('WFD_SLOW_NODE', { label: 'slow' })
const timer = new Promise(r => setTimeout(() => r('WFD_DEADLINE_HIT'), 3000))
const winner = await Promise.race([slow, timer])
return { winner }
"""
WF_BUDGET = r"""export const meta = { name: 'bud', description: 'budget probe' }
return { total: budget.total, remaining: String(budget.remaining()) }
"""


def mk_wf_one(script, node_delay):
    def f(body, n, st):
        if kind(body) == "main":
            record(body, n, st)
            if not tool_results(body):
                return [tu("Workflow", {"script": script})], "tool_use", 0
            return TXT("WF1_MAIN_DONE")
        record(body, n, st, t=time.time())
        return [{"type": "text", "text": "WF1_NODE_DONE"}], "end_turn", node_delay
    return f


def wf_budget_sdk_driver(argv, cwd, env, out):
    p, send, wait, user, events, lock = ctl_session(argv, cwd, env)
    send({"type": "control_request", "request_id": "i", "request": {"subtype": "initialize"}})
    wait(resp("i"))
    user("+50k use a workflow")
    log = [{"result": bool(wait(lambda e: e.get("type") == "result", 90))}]
    return ctl_finish(p, out, log, events, lock)


CASES.update({
    "dmu_wf_stall": {"fn": mk_wf_one(WF_STALL, 30), "argv": P + BYP + ["wf"], "timeout": 180},
    "dmu_wf_deadline": {"fn": mk_wf_one(WF_DEADLINE, 20), "argv": P + BYP + ["wf"], "timeout": 120},
    "dmu_wf_budget_sdk": {"fn": mk_wf_one(WF_BUDGET, 0), "driver": wf_budget_sdk_driver,
                          "argv": SDK + BYP, "timeout": 120},
})


# ---- 5. `claude mcp serve` lifecycle: TaskStop, SendMessage, tools/call cancel ---------------
def f_mcp(body, n, st):
    fu = first_user_text(body)
    record(body, n, st)
    if "MCP_SLOW" in fu or "MCP_WF_SLOW" in fu:
        return [{"type": "text", "text": "MCP_SLOW_DONE"}], "end_turn", 25
    if "MCP_FOLLOW_77" in text_of(body):
        return TXT("MCP_FOLLOW_ACK_77")
    return TXT("MCP_CHILD_RESULT_23")


def mcp_session(argv, cwd, env):
    import subprocess
    import threading
    p = subprocess.Popen([argv[0], "mcp", "serve"], cwd=cwd, env=env, stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    msgs, lock = [], threading.Lock()

    def rd():
        for line in p.stdout:
            try:
                d = json.loads(line)
            except Exception:
                d = {"raw": line}
            d["_t"] = time.time()
            with lock:
                msgs.append(d)
    threading.Thread(target=rd, daemon=True).start()

    def send(o):
        p.stdin.write(json.dumps(o) + "\n")
        p.stdin.flush()

    def call(i, name, args):
        send({"jsonrpc": "2.0", "id": i, "method": "tools/call", "params": {"name": name, "arguments": args}})

    def reply(i, to=60):
        end = time.time() + to
        while time.time() < end:
            with lock:
                for d in msgs:
                    if d.get("id") == i:
                        return d
            time.sleep(0.1)
        return {"_timeout": to}
    send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "probe", "version": "0"}}})
    reply(1)
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    return p, send, call, reply


def mcp_text(r):
    try:
        return " ".join(c.get("text", "") for c in r["result"]["content"])
    except Exception:
        return json.dumps(r)[:1500]


def mcp_lifecycle_driver(argv, cwd, env, out):
    """(a) sync Agent -> SendMessage to its agentId -> ListAgents; (b) Workflow -> TaskStop;
    (c) slow Agent -> notifications/cancelled. Times are seconds since driver start (t0)."""
    p, send, call, reply = mcp_session(argv, cwd, env)
    t0 = time.time()
    rel = lambda: round(time.time() - t0, 1)
    log = {"t0": t0}
    call(2, "Agent", {"description": "mcp", "prompt": "MCP_CHILD"})
    a = json.loads(mcp_text(reply(2)) or "{}")
    log["agent"] = {k: a.get(k) for k in ("status", "agentId", "resolvedModel")}
    call(3, "SendMessage", {"to": a.get("agentId") or "x", "summary": "follow", "message": "MCP_FOLLOW_77 one more"})
    log["sendmessage"] = mcp_text(reply(3))[:600]
    call(4, "ListAgents", {})
    log["listagents"] = mcp_text(reply(4, 20))[:400]
    script = "export const meta = { name: 'm', description: 'mcp wf' }\nreturn await agent('MCP_WF_SLOW', {})\n"
    log["wf_call_at"] = rel()
    call(5, "Workflow", {"script": script})
    w = json.loads(mcp_text(reply(5)) or "{}")
    log["workflow"] = {k: w.get(k) for k in ("status", "taskId", "runId")}
    time.sleep(3)
    log["taskstop_at"] = rel()
    call(6, "TaskStop", {"task_id": w.get("taskId") or "x"})
    log["taskstop"] = mcp_text(reply(6))[:400]
    time.sleep(8)
    log["slow_agent_at"] = rel()
    call(7, "Agent", {"description": "slow", "prompt": "MCP_SLOW"})
    time.sleep(4)
    log["cancel_at"] = rel()
    send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": 7, "reason": "probe"}})
    r7 = reply(7, 40)
    log["after_cancel"] = {"got_reply": "_timeout" not in r7, "reply_at": round(r7["_t"] - t0, 1) if "_t" in r7 else None,
                           "text": mcp_text(r7)[:300]}
    call(8, "ListAgents", {})
    log["alive_after_cancel"] = "_timeout" not in reply(8, 10)
    p.kill()
    (out / "driver-log.json").write_text(json.dumps(log, indent=1, default=str))
    return 0, json.dumps(log)[:6000], p.stderr.read()[-2000:]


def mcp_wf_alone_driver(argv, cwd, env, out):
    """Workflow over MCP with no further calls: does the node finish or get cut?"""
    p, send, call, reply = mcp_session(argv, cwd, env)
    t0 = time.time()
    script = "export const meta = { name: 'm', description: 'mcp wf' }\nreturn await agent('MCP_WF_SLOW', {})\n"
    call(2, "Workflow", {"script": script})
    w = json.loads(mcp_text(reply(2)) or "{}")
    time.sleep(35)
    log = {"t0": t0, "workflow": {k: w.get(k) for k in ("status", "taskId")}}
    p.kill()
    (out / "driver-log.json").write_text(json.dumps(log, indent=1, default=str))
    return 0, json.dumps(log), p.stderr.read()[-2000:]


CASES["dmu_mcp_lifecycle"] = {"fn": f_mcp, "driver": mcp_lifecycle_driver, "argv": [], "timeout": 200}
CASES["dmu_mcp_wf_alone"] = {"fn": f_mcp, "driver": mcp_wf_alone_driver, "argv": [], "timeout": 120}

# ---- 6. skill context: fork --------------------------------------------------------------
FORK_SKILL = """---
name: forky
description: Probe skill that runs in a forked context.
context: fork
model: opus
effort: low
---
FORKY_SKILL_BODY_6060
"""
INLINE_SKILL = """---
name: inliney
description: Probe skill that runs inline.
---
INLINEY_SKILL_BODY_6161
"""


def prep_skills():
    for name, body in (("forky", FORK_SKILL), ("inliney", INLINE_SKILL)):
        d = WORK / "fixture" / ".claude" / "skills" / name
        d.mkdir(parents=True, exist_ok=True)
        (d / "SKILL.md").write_text(body)


def mk_skill(skill):
    def f(body, n, st):
        allu = text_of(body)
        k = kind(body)
        has_body = "FORKY_SKILL_BODY_6060" in allu or "INLINEY_SKILL_BODY_6161" in allu
        record(body, n, st, has_skill_body=has_body)
        if k == "main" and not tool_results(body):
            return [tu("Skill", {"skill": skill})], "tool_use", 0
        if k == "main":
            return TXT("SKILL_MAIN_DONE")
        if has_tool := any(t.get("name") == "Agent" for t in body.get("tools", [])):
            st["data"]["fork_child_has_agent"] = has_tool
        return TXT("SKILL_CHILD_DONE")
    return f


CASES.update({
    "dmu_skill_fork": {"fn": mk_skill("forky"), "prep": prep_skills, "argv": PS + BYP + ["skill"]},
    "dmu_skill_inline": {"fn": mk_skill("inliney"), "prep": prep_skills, "argv": PS + BYP + ["skill"]},
})

# ---- 7. plugin $.model.fork / $.model.complete --------------------------------------------
MODEL_MOD = S / "mods" / "model-fork"


def f_plugin_model(body, n, st):
    allu = text_of(body)
    tag = "fork" if "PLUGIN_FORK_PROBE_5151" in allu else "complete" if "PLUGIN_COMPLETE_PROBE_5252" in allu else "main"
    record(body, n, st, tag=tag)
    if tag == "fork":
        return [tu("Bash", {"command": "echo FORK_TRIED_TOOL", "description": "x"}, n)], "tool_use", 0
    return TXT(f"PLUGIN_{tag.upper()}_REPLY")


CASES["dmu_plugin_model"] = {"fn": f_plugin_model, "argv": PS + ["--plugin-dir", str(MODEL_MOD), "hello"],
                             "timeout": 90}


# ---- 8. hook type:"agent" ------------------------------------------------------------------
def f_hook_agent(body, n, st):
    k = kind(body)
    record(body, n, st)
    if k == "hook_agent":
        so = next((t["name"] for t in body.get("tools", []) if "Structured" in t.get("name", "")), None)
        if so and not last_user_has_tool_result(body):
            return [tu(so, {"ok": True}, n)], "tool_use", 0
        return TXT("HOOK_AGENT_DONE")
    if k == "main" and not tool_results(body):
        return [tu("Agent", {"description": "sub", "prompt": "HA_CHILD", "run_in_background": False})], "tool_use", 0
    return TXT("HA_DONE")


HOOK_AGENT_SETTINGS = json.dumps({"hooks": {
    "Stop": [{"hooks": [{"type": "agent", "prompt": "HOOKAGENT_STOP_PROBE verify done", "timeout": 30}]}],
    "SubagentStop": [{"hooks": [{"type": "agent", "prompt": "HOOKAGENT_SUBSTOP_PROBE verify",
                                 "model": "sonnet", "timeout": 30}]}]}})
CASES["dmu_hook_agent"] = {"fn": f_hook_agent, "argv": P + BYP + ["--settings", HOOK_AGENT_SETTINGS, "go"],
                           "timeout": 120}


# ---- 9. Monitor gate -----------------------------------------------------------------------
def f_inv(body, n, st):
    record(body, n, st)
    return TXT("INVENTORY_DONE")


def seed_flags(case, flags):
    def prep():
        (WORK / "cfg" / case / ".claude.json").write_text(json.dumps({"cachedGrowthBookFeatures": flags}))
    return prep


CASES.update({
    "dmu_monitor_default": {"fn": f_inv, "argv": P + ["--tools=default", "hello"]},
    "dmu_monitor_flag": {"fn": f_inv, "prep": seed_flags("dmu_monitor_flag", {"tengu_amber_sentinel": True}),
                         "argv": P + ["--tools=default", "hello"]},
})
CASES["dmu_monitor_flag_1p"] = {**CASES["dmu_monitor_flag"],
                                "prep": seed_flags("dmu_monitor_flag_1p", {"tengu_amber_sentinel": True}),
                                "env": {"_CLAUDE_CODE_ASSUME_FIRST_PARTY_BASE_URL": "1"}}
HOOK_AGENT_MODEL_SETTINGS = json.dumps({"hooks": {
    "Stop": [{"hooks": [{"type": "agent", "prompt": "HOOKAGENT_STOP_PROBE verify done", "model": "opus",
                         "timeout": 30}]}],
    "SubagentStop": [{"hooks": [{"type": "agent", "prompt": "HOOKAGENT_SUBSTOP_PROBE verify", "timeout": 30}]}]}})
CASES["dmu_hook_agent_model"] = {"fn": f_hook_agent, "argv": PS + BYP + ["--settings", HOOK_AGENT_MODEL_SETTINGS, "go"],
                                 "timeout": 120}
HOOK_AGENT_MODEL2_SETTINGS = json.dumps({"hooks": {
    "Stop": [{"hooks": [{"type": "agent", "prompt": "HOOKAGENT_STOP_PROBE verify done", "model": "haiku",
                         "timeout": 30}]}],
    "SubagentStop": [{"hooks": [{"type": "agent", "prompt": "HOOKAGENT_SUBSTOP_PROBE verify",
                                 "model": "claude-opus-5-5", "timeout": 30}]}]}})
CASES["dmu_hook_agent_model2"] = {"fn": f_hook_agent,
                                  "argv": PS + BYP + ["--settings", HOOK_AGENT_MODEL2_SETTINGS, "go"], "timeout": 120}


# ---- 10. `--bg` background session daemon (offline, isolated config) ----------------------
def f_bgd(body, n, st):
    record(body, n, st)
    return TXT("BGD_REPLY_4141")


def bg_daemon_driver(argv, cwd, env, out):
    import subprocess
    claude = argv[0]
    log = {}

    def run(args, to=30):
        r = subprocess.run([claude] + args, cwd=cwd, env=env, capture_output=True, text=True, timeout=to, input="")
        return {"rc": r.returncode, "stdout": r.stdout[-1500:], "stderr": r.stderr[-800:]}
    log["start"] = run(["--bg", "--model", "sonnet", "--effort", "low", "--permission-mode", "default",
                        "BGD_PROBE_4040 reply hi"])
    sid = (re.findall(r"\b([0-9a-f]{6,}|[a-z0-9]{8})\b", log["start"]["stdout"]) or [None])[0]
    log["id"] = sid
    time.sleep(12)
    log["agents_json"] = run(["agents", "--json", "--all"])
    if sid:
        log["logs"] = run(["logs", sid])
        log["stop"] = run(["stop", sid])
        time.sleep(2)
        log["rm"] = run(["rm", sid])
    log["agents_after"] = run(["agents", "--json", "--all"])
    # `stop`/`rm` leave the transient daemon running; record it, then end it.
    ps = subprocess.run(["ps", "-eo", "pid,args"], capture_output=True, text=True).stdout.splitlines()
    daemons = [l.split(None, 1) for l in ps if "daemon run --origin transient" in l and str(WORK / "fixture") in l]
    log["daemon_left_running"] = len(daemons)
    for pid, _ in daemons:
        subprocess.run(["kill", pid])
    (out / "driver-log.json").write_text(json.dumps(log, indent=1, default=str))
    return 0, json.dumps(log)[:6000], ""


def seed_trust(case):
    def prep():
        fx = str(WORK / "fixture")
        (WORK / "cfg" / case / ".claude.json").write_text(json.dumps(
            {"projects": {fx: {"hasTrustDialogAccepted": True}}}))
        # The --bg daemon session does not see ANTHROPIC_API_KEY ("Not logged in"); hand it the mock key
        # through apiKeyHelper in user settings instead.
        (WORK / "cfg" / case / "settings.json").write_text(json.dumps({"apiKeyHelper": "echo mock-not-a-real-key"}))
    return prep


CASES["dmu_bg_daemon"] = {"fn": f_bgd, "driver": bg_daemon_driver, "prep": seed_trust("dmu_bg_daemon"), "argv": [],
                          "timeout": 150}
