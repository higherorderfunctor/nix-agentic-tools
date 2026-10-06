import json,sys
# Print tool results (and tool uses) in the history/current message of GenerateAssistantResponse requests whose rule == argv[2] (or all).
p=sys.argv[1]; want=sys.argv[2] if len(sys.argv)>2 else None
for line in open(p):
    d=json.loads(line)
    if 'body' not in d or 'GenerateAssistant' not in d['target']: continue
    if want is not None and str(d['rule'])!=want: continue
    b=json.loads(d['body']); cs=b['conversationState']
    msgs=cs.get('history',[])+[cs['currentMessage']]
    for m in msgs:
        u=m.get('userInputMessage'); a=m.get('assistantResponseMessage')
        if u:
            for r in (u.get('userInputMessageContext',{}).get('toolResults') or []):
                print(f"rule={d['rule']} TOOL_RESULT {r.get('toolUseId')} status={r.get('status')} {json.dumps(r.get('content'))[:600]}")
        if a:
            for tu in (a.get('toolUses') or []): print(f"rule={d['rule']} TOOL_USE {tu.get('toolUseId')} {tu.get('name')} {json.dumps(tu.get('input'))[:200]}")
