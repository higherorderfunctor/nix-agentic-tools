import json,sys,re
# Summarize a capserver2 wire.jsonl: one line per GenerateAssistantResponse with model/effort/markers.
# Usage: wiresum.py <wire.jsonl> [MARKER ...]
p=sys.argv[1]; marks=sys.argv[2:]
for line in open(p):
    d=json.loads(line)
    if 'body' not in d:
        print(f"{d['t']:7} ..", {k:v for k,v in d.items() if k!='t'}); continue
    t=d['target'].split('.')[-1]
    if 'GenerateAssistant' not in t: print(f"{d['t']:7} {t}"); continue
    try: b=json.loads(d['body'])
    except Exception: print(d['t'],'unparsable'); continue
    cs=b.get('conversationState',{}); cm=cs.get('currentMessage',{}).get('userInputMessage',{})
    ctx=cm.get('userInputMessageContext',{}); tools=[x.get('toolSpecification',{}).get('name') for x in ctx.get('tools',[])]
    extra={k:v for k,v in b.items() if k not in('conversationState','profileArn')}
    hits=[m for m in marks if m in d['body']]
    print(f"{d['t']:7} rule={d['rule']} conv={cs.get('conversationId','')[:8]} model={cm.get('modelId')} extra={json.dumps(extra)[:200]} hist={len(cs.get('history',[]))} tools={len(tools)} hits={hits}")
    if '-v' in marks: print('   tools:',tools)
