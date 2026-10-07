"""Summarize out/<run>/provider.jsonl: relative time, role, model, effort, delegate tools, markers.
LIVE runs (recproxy.py) print one RESP line per chat response: model/effort sent, model(s) returned,
reasoning tokens. ACP runs also print the client-visible timeline from stdout: responses and
agent_message_chunk text, one `acp` line each."""
import json, os, sys
rows = [json.loads(l) for l in open(sys.argv[1] + "/provider.jsonl")]
t0 = next((r["t"] for r in rows if r["kind"] == "POST"), rows[0]["t"])
D = ("Agent", "resume_subagent", "steer_subagent", "get_subagent_result", "dispatch_to_cloud_agent")
for r in rows:
    k = r["kind"]; dt = f'{r["t"] - t0:7.2f}'
    if k == "POST" and "role" in r:
        if r["path"] == "/chat/completions": continue
        print(dt, r["role"], r["model"], r["reasoning_effort"], f'tools={len(r["tools"])}', [t for t in r["tools"] if t in D], f'nasst={r["n_asst"]}', r["first_user_head"][:40].replace("\n", " "), "| last:", r["last_text"][:110].replace("\n", " "), "| steers:", r["steers_seen"])
    elif k == "RESP":
        u = r.get("usage") or {}
        print(dt, "RESP", r["status"], f'sent={r["sent_model"]}/{r["sent_effort"]}', f'resp={",".join(r["resp_models"])}',
              f'reasoning_tokens={(u.get("completion_tokens_details") or {}).get("reasoning_tokens")}')
    elif k in ("client_disconnected", "PLAN_STEP"):
        print(dt, k, {x: r[x] for x in r if x not in ("kind", "t")})
stdout = sys.argv[1] + "/stdout"
if os.path.exists(stdout):
    for line in open(stdout, errors="replace"):
        try:
            o = json.loads(line); m = json.loads(o["msg"])
        except (ValueError, KeyError, TypeError):
            continue
        u = (m.get("params") or {}).get("update") or {}
        if "result" in m and "id" in m:
            print(f'{o["t"]:7.2f}', "acp", "response", m["id"], json.dumps(m["result"])[:60])
        elif u.get("sessionUpdate") == "agent_message_chunk":
            print(f'{o["t"]:7.2f}', "acp", "agent_message_chunk", (u.get("content") or {}).get("text", "")[:60])
