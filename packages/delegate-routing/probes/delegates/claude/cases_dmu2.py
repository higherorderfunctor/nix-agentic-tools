"""Delegate-map unknown cases, round 2 (`--bg` limits, agent teams). Registered into cases.CASES.

Each case runs the pinned binary against the harness mock: `python3 harness.py <case>`, then
`python3 dmu_show.py <case>` prints one line per request and the driver log.
"""
import json
import re
import shlex
import subprocess
import time
import uuid

from harness import WORK, tool_results
from cases_dmu import TXT, first_user_text, kind, record, seed_trust, tu

CASES = {}
# The driver runs in harness's __main__ module while this module sees an imported copy, so the mock
# function hands the live STATE over here.
LIVE = {}


def answered(body):
    """True once this conversation already holds an assistant turn: the mock acts only on an
    agent's first request, so notifications and interrupted-turn markers never re-trigger it."""
    return any(m.get("role") == "assistant" for m in body.get("messages", []))


def ids_in(text):
    return re.findall(r"\b([0-9a-f]{8})\b", text)


def cli(claude, cwd, env):
    def run(args, to=30):
        r = subprocess.run([claude] + args, cwd=cwd, env=env, capture_output=True, text=True, timeout=to, input="")
        return {"rc": r.returncode, "stdout": r.stdout, "stderr": r.stderr[-800:]}
    return run


AGENTS_RAW = []


def agents(run):
    r = run(["agents", "--json", "--all"])
    AGENTS_RAW.append(r)
    try:
        return json.loads(r["stdout"] or "[]")
    except ValueError:
        return []


def wait_for(pred, to):
    end = time.time() + to
    while time.time() < end:
        if pred():
            return True
        time.sleep(0.5)
    return False


def kill_daemons():
    ps = subprocess.run(["ps", "-eo", "pid,args"], capture_output=True, text=True).stdout.splitlines()
    pids = [line.split(None, 1)[0] for line in ps
            if "daemon run --origin transient" in line and str(WORK / "fixture") in line]
    for pid in pids:
        subprocess.run(["kill", pid])
    return len(pids)


# ---- 11. `--bg` limits: session concurrency, Agent depth, respawn, attach --------------------
HOLD_S = 30
N_HOLD = 4


def f_bgl(body, n, st):
    LIVE["st"] = st
    first = first_user_text(body)
    hold = re.search(r"BGL_HOLD_(\d)", first)
    depth = re.findall(r"DEPTH=(\d+)", first)
    k = kind(body)
    tools = [t.get("name") for t in body.get("tools", [])]
    if not tools:  # title / summary side calls
        record(body, n, st, tag="side")
        return TXT("BGL_SIDE")
    if hold:
        record(body, n, st, tag=f"hold{hold.group(1)}", t=round(time.time(), 1))
        st["data"].setdefault("hold_starts", []).append([int(hold.group(1)), time.time()])
        if answered(body):
            return TXT("BGL_HELD_DONE")
        return TXT(f"BGL_HELD_{hold.group(1)}")[0], "end_turn", HOLD_S
    if depth:
        d = int(depth[-1])
        record(body, n, st, tag=f"depth{d}")
        st["data"].setdefault("depth_tools", {})[str(d)] = "Agent" in tools
        if answered(body):
            return TXT(f"DEPTH_DONE {d}")
        if "Agent" in tools and d < 8:
            return [tu("Agent", {"description": f"depth {d + 1}", "subagent_type": "general-purpose",
                                 "prompt": f"DEPTH={d + 1} spawn deeper", "run_in_background": False}, d)], "tool_use", 0
        st["data"]["depth_leaf"] = d
        return TXT(f"LEAF depth={d} no Agent tool")
    record(body, n, st, tag=k)
    return TXT("BGL_OTHER")


def max_overlap(starts, width):
    times = sorted(t for _, t in starts)
    return max((sum(1 for u in times if t <= u < t + width) for t in times), default=0)


def bg_limits_driver(argv, cwd, env, out):
    run = cli(argv[0], cwd, env)
    log = {"hold_s": HOLD_S}
    common = ["--model", "sonnet", "--effort", "low", "--permission-mode", "default"]
    ids = []
    for i in range(N_HOLD):
        r = run(["--bg", *common, f"BGL_HOLD_{i} reply hi"])
        log[f"start_hold{i}"] = r["stdout"].splitlines()[0] if r["stdout"] else r
        ids += ids_in(r["stdout"])[:1]
    log["hold_ids"] = ids
    wait_for(lambda: len(LIVE.get("st", {}).get("data", {}).get("hold_starts", [])) >= N_HOLD, 40)
    listed = agents(run)
    log["listed_while_held"] = [{k: a.get(k) for k in ("id", "kind", "status", "state")} for a in listed]
    # Depth: one more session whose main spawns Agent until the tool is withheld.
    r = run(["--bg", *common, "BGL_DEPTH DEPTH=0 spawn"])
    log["start_depth"] = r["stdout"].splitlines()[0] if r["stdout"] else r
    depth_id = (ids_in(r["stdout"]) or [None])[0]
    wait_for(lambda: "depth_leaf" in LIVE["st"]["data"], 60)
    log["depth_agent_by_level"] = LIVE["st"]["data"].get("depth_tools")
    log["depth_leaf"] = LIVE["st"]["data"].get("depth_leaf")
    starts = LIVE["st"]["data"].get("hold_starts", [])
    log["held_mains_overlapping"] = max_overlap(starts, HOLD_S)
    # respawn: let the held turns finish, then restart one session and compare its pid.
    time.sleep(HOLD_S + 2)
    target = ids[0] if ids else None
    if target:
        before = {a["id"]: a.get("pid") for a in agents(run)}
        n_before = LIVE["st"]["n"]
        log["respawn"] = run(["respawn", target], to=60)
        time.sleep(8)
        after = {a["id"]: a for a in agents(run)}
        log["respawn_pid_before"] = before.get(target)
        log["respawn_pid_after"] = (after.get(target) or {}).get("pid")
        log["respawn_status_after"] = (after.get(target) or {}).get("status")
        log["respawn_new_requests"] = LIVE["st"]["n"] - n_before
    # attach: open one session in a tmux pane, read the screen, leave it.
    if len(ids) > 1:
        sock = ["tmux", "-L", f"claude-bgl-{uuid.uuid4().hex}"]
        tenv = {**env, "TERM": "xterm-256color"}
        subprocess.run(sock + ["new-session", "-d", "-s", "a", "-c", cwd, "-x", "160", "-y", "45",
                               shlex.join([argv[0], "attach", ids[1]])], env=tenv, check=True)
        time.sleep(8)
        pane = subprocess.run(sock + ["capture-pane", "-p", "-t", "a"], capture_output=True, text=True).stdout
        (out / "attach-pane.txt").write_text(pane)
        log["attach_pane_has_reply"] = "BGL_HELD_1" in pane
        log["attach_pane_has_prompt"] = "BGL_HOLD_1" in pane
        subprocess.run(sock + ["kill-server"], capture_output=True)
        time.sleep(2)
        log["attached_session_after_detach"] = next(
            ({k: a.get(k) for k in ("id", "status")} for a in agents(run) if a.get("id") == ids[1]), None)
    for sid in ids + ([depth_id] if depth_id else []):
        run(["stop", sid])
        run(["rm", sid])
    log["agents_after_rm"] = agents(run)
    log["agents_calls_rc"] = [r["rc"] for r in AGENTS_RAW]
    log["daemons_killed"] = kill_daemons()
    (out / "driver-log.json").write_text(json.dumps(log, indent=1, default=str))
    return 0, json.dumps(log)[:6000], ""


CASES["dmu_bg_limits"] = {"fn": f_bgl, "driver": bg_limits_driver, "prep": seed_trust("dmu_bg_limits"),
                          "argv": [], "timeout": 300}


# ---- 12. agent teams in the TUI: concurrency, idle/wake by SendMessage, TaskStop by name -----
TEAM_SEED = {"hasCompletedOnboarding": True, "theme": "dark"}


def last_tool_use(body):
    """Name of the tool the latest assistant turn called, "text" if it called none, None if no turn."""
    for m in reversed(body.get("messages", [])):
        if m.get("role") == "assistant":
            c = m.get("content")
            names = [x.get("name") for x in c if isinstance(x, dict) and x.get("type") == "tool_use"] \
                if isinstance(c, list) else []
            return names[-1] if names else "text"
    return None


def last_result(body):
    trs = tool_results(body)
    c = trs[-1].get("content") if trs else None
    if isinstance(c, list):
        c = " ".join(x.get("text", "") for x in c if isinstance(x, dict))
    return (c or "")[:160]


def identity(body):
    s = body.get("system")
    return s[1].get("text", "")[:60] if isinstance(s, list) and len(s) > 1 else ""


def f_team(body, n, st):
    LIVE["st"] = st
    first = first_user_text(body)
    every = json.dumps(body.get("messages", []))
    data = st["data"]
    if not body.get("tools"):
        record(body, n, st, tag="side")
        return TXT("TEAM_SIDE")
    if "TEAMMATE_ALICE" in first:
        if "WAKE_PING_7070" in every and not data.get("alice_woke"):
            data["alice_woke"] = {"n": n, "kept_history": "ALICE_FIRST_DONE" in every}
            record(body, n, st, tag="alice_wake")
            return TXT("ALICE_ACK_7171")
        record(body, n, st, tag="alice" if not answered(body) else "alice_again")
        if answered(body):
            return TXT("ALICE_AGAIN")
        data["teammate_identity"] = identity(body)
        return TXT("ALICE_FIRST_DONE")[0], "end_turn", 3
    if "TEAMMATE_BOB" in first:
        record(body, n, st, tag="bob" if not answered(body) else "bob_again")
        if answered(body):
            return TXT("BOB_AGAIN")
        data["bob_n"] = n
        return TXT("BOB_LATE")[0], "end_turn", 60
    step = last_tool_use(body)
    record(body, n, st, tag=f"main_after_{step}")
    if step is None:
        spawn = [tu("Agent", {"description": f"{who} teammate", "subagent_type": "general-purpose", "name": who,
                              "team_name": "probe", "run_in_background": True,
                              "prompt": f"TEAMMATE_{who.upper()} reply once"}, i)
                 for i, who in enumerate(("alice", "bob"))]
        return spawn, "tool_use", 0
    if step == "Agent":  # let alice finish and go idle before the message
        return [tu("SendMessage", {"to": "alice", "summary": "wake probe",
                                   "message": "WAKE_PING_7070 reply ALICE_ACK"}, n)], "tool_use", 8
    if step == "SendMessage":
        data["send_result"] = last_result(body)
        data["stop_t"] = time.time()
        return [tu("TaskStop", {"task_id": "bob"}, n)], "tool_use", 0
    if step == "TaskStop":
        data["stop_result"] = last_result(body)
        data["main_done"] = True
        return TXT("TEAM_MAIN_DONE")
    return TXT("TEAM_MAIN_NOTE")


def mk_team_driver(settings):
    def driver(argv, cwd, env, out):
        cfg = env["CLAUDE_CONFIG_DIR"]
        with open(f"{cfg}/.claude.json", "w") as fh:
            json.dump({**TEAM_SEED, "projects": {cwd: {"hasCompletedProjectOnboarding": True,
                                                        "hasTrustDialogAccepted": True}}}, fh)
        tui = [argv[0], "--model", "sonnet", "--permission-mode", "default",
               "--allowedTools", "Agent", "SendMessage", "TaskStop",
               "--settings", json.dumps(settings), "TEAM_GO"]
        sock = ["tmux", "-L", f"claude-team-{uuid.uuid4().hex}"]
        tenv = {**env, "TERM": "xterm-256color", "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"}
        log = {"settings": settings}
        subprocess.run(sock + ["new-session", "-d", "-s", "t", "-c", cwd, "-x", "200", "-y", "50", shlex.join(tui)],
                       env=tenv, check=True)
        try:
            end = time.time() + 150
            while time.time() < end:
                time.sleep(0.5)
                pane = subprocess.run(sock + ["capture-pane", "-p", "-t", "t"], capture_output=True,
                                      text=True).stdout
                if "Do you want to use this API key?" in pane:
                    subprocess.run(sock + ["send-keys", "-t", "t", "Up", "Enter"])
                elif "Enter to continue" in pane:  # one-time notice dialogs
                    subprocess.run(sock + ["send-keys", "-t", "t", "Enter"])
                data = LIVE.get("st", {}).get("data", {})
                if data.get("main_done") and data.get("alice_woke"):
                    # bob's request is held 60 s: wait for it to close (TaskStop abort) or to complete
                    if wait_for(lambda: any(e["n"] == data.get("bob_n") for e in LIVE["st"]["log"]), 65):
                        log["stop_to_bob_end_s"] = round(time.time() - data["stop_t"])
                    time.sleep(3)
                    break
            log["panes"] = subprocess.run(sock + ["list-panes", "-a", "-F", "#{pane_current_command}"],
                                          capture_output=True, text=True).stdout.split()
            (out / "pane.txt").write_text(subprocess.run(sock + ["capture-pane", "-p", "-t", "t"],
                                                         capture_output=True, text=True).stdout)
        finally:
            subprocess.run(sock + ["kill-server"], capture_output=True)
        st = LIVE.get("st", {"data": {}, "log": [], "max_inflight": 0})
        tags = [r.get("tag") for r in st["data"].get("reqs", [])]
        log["teammate_requests"] = [t for t in tags if t and t.split("_")[0] in ("alice", "bob")]
        log["alice_woke"] = st["data"].get("alice_woke")
        bob = [e["reply"][0] for e in st["log"] if e["n"] == st["data"].get("bob_n")]
        log["bob_request"] = bob[0] if bob else "still open"
        log["bob_reply_shown"] = "BOB_LATE" in (out / "pane.txt").read_text()
        log["max_inflight"] = st["max_inflight"]
        log["main_done"] = bool(st["data"].get("main_done"))
        log["send_result"] = st["data"].get("send_result")
        log["stop_result"] = st["data"].get("stop_result")
        log["teammate_identity"] = st["data"].get("teammate_identity")
        (out / "driver-log.json").write_text(json.dumps(log, indent=1, default=str))
        return 0, json.dumps(log)[:6000], ""
    return driver


CASES["dmu_team_tui"] = {"fn": f_team, "driver": mk_team_driver({}), "argv": [], "timeout": 200}
CASES["dmu_team_tui_tmux"] = {"fn": f_team, "driver": mk_team_driver({"teammateMode": "tmux"}), "argv": [],
                              "timeout": 200}
