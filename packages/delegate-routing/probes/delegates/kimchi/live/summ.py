"""Summarize out/<run>/provider.jsonl: relative time, role, model, effort, delegate tools, markers."""
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1] + "/provider.jsonl")]
t0 = next((r["t"] for r in rows if r["kind"] == "POST"), rows[0]["t"])
D = ("Agent", "resume_subagent", "steer_subagent", "get_subagent_result", "dispatch_to_cloud_agent")
for r in rows:
    k = r["kind"]; dt = f'{r["t"] - t0:7.2f}'
    if k == "POST":
        if r["path"] == "/chat/completions": continue
        print(dt, r["role"], r["model"], r["reasoning_effort"], f'tools={len(r["tools"])}', [t for t in r["tools"] if t in D], f'nasst={r["n_asst"]}', r["first_user_head"][:40].replace("\n", " "), "| last:", r["last_text"][:110].replace("\n", " "), "| steers:", r["steers_seen"])
    elif k in ("client_disconnected", "PLAN_STEP"):
        print(dt, k, {x: r[x] for x in r if x not in ("kind", "t")})
