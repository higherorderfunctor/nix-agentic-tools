#!/usr/bin/env python3
"""Peak concurrency of scripted model requests in a capserver2 wire.jsonl.

usage: python3 inflight.py <wire.jsonl> <marker>

Counts GenerateAssistantResponse requests whose body contains <marker>, then
sweeps the log in write order: +1 when such a request arrives, -1 when the
server answers (or loses) the rule it matched. Prints
`marker=<m> requests=<n> peak_inflight=<p> first_answer_t=<t> arrived_before_first_answer=<k>`
and `conversations=<distinct conversationState.conversationId among them>`.
Give the marker's rule a `delay` (and `reuse`) so the requests overlap.
"""

import json
import sys

if len(sys.argv) != 3:
    sys.exit(__doc__)
path, marker = sys.argv[1:]
rows = [json.loads(line) for line in open(path, encoding="utf-8") if line.strip()]
rules = {
    r["rule"]
    for r in rows
    if "GenerateAssistantResponse" in r.get("target", "") and marker in r.get("body", "") and r.get("rule") is not None
}
requests = live = peak = before = 0
first = None
conversations = set()
for r in rows:
    if "body" in r and r.get("rule") in rules and marker in r["body"]:
        requests += 1
        live += 1
        conversations.add(json.loads(r["body"]).get("conversationState", {}).get("conversationId"))
        peak = max(peak, live)
        if first is None:
            before += 1
    elif r.get("answered", r.get("client_gone")) in rules and ("answered" in r or "client_gone" in r):
        live -= 1
        if first is None:
            first = r["t"]
print(
    f"marker={marker} requests={requests} peak_inflight={peak} first_answer_t={first} arrived_before_first_answer={before}"
)
print(f"conversations={len(conversations)}")
