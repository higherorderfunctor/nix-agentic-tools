import hashlib,json,pathlib
# codex:R9 — summarizes <work>/runs/* of offline.py into ./wire-summary.json and asserts the scoped findings.
# usage: python3 summarize.py <work>
import sys
S=pathlib.Path(sys.argv[1])
out={}
for name in ['v2-controls','v2-flags','v2-headless','v3-controls','v3-deny','v3-inline','v3-nested','v3-workflow','v3-pause','v3-workflow-ungated']:
 R=S/'runs'/name; requests=[]; schemas={}
 for line in (R/'wire.jsonl').read_text().splitlines():
  x=json.loads(line)
  if 'GenerateAssistantResponse' not in x['target']:continue
  c=json.loads(x['body'])['conversationState'];m=c['currentMessage']['userInputMessage']
  requests.append({'modelId':m.get('modelId'),'content':m.get('content','')[:160],'rule':x['rule'],'tools':[t['toolSpecification']['name'] for t in m.get('userInputMessageContext',{}).get('tools',[])]})
  for t in m.get('userInputMessageContext',{}).get('tools',[]):
   spec=t['toolSpecification'];schemas.setdefault(spec['name'],spec)
 events=[]
 if (R/'acp.jsonl').exists():
  events=[json.loads(l[3:]) for l in (R/'acp.jsonl').read_text().splitlines() if l.startswith('<< ')]
 results=[x for x in events if 'result' in x and x.get('id') is not None]
 errors=[x for x in events if 'error' in x]
 out[name]={'requests':requests,'toolNames':sorted(schemas),'schemas':{k:v for k,v in schemas.items() if 'agent' in k or 'workflow' in k or 'message' in k},'results':results,'errors':errors,'exit':json.loads((R/'exit.json').read_text())}
pathlib.Path('wire-summary.json').write_text(json.dumps(out,indent=2))
assert any(r['modelId']=='claude-haiku-4.5' for r in out['v2-headless']['requests'])
assert 'approval is not supported in non-interactive mode' in (S/'runs/v2-headless/out.txt').read_text()
assert any(x.get('error',{}).get('code')==-32601 for x in out['v2-controls']['errors'])
assert any(x.get('result',{}).get('stopReason')=='cancelled' for x in out['v3-controls']['results'])
assert 'inlineAgent' in out['v3-inline']['schemas']['invoke_sub_agent']['inputSchema']['json']['properties']
assert any(r['modelId']=='claude-haiku-4.5' for r in out['v3-inline']['requests'])
assert any(x.get('result',{}).get('state',{}).get('capturedOutputs',{}).get('one')=='WORKFLOW_RETRY_DONE' for x in out['v3-workflow']['results'])
assert any(x.get('result',{}).get('_meta',{}).get('workflowsEnabled') is False for x in out['v3-workflow-ungated']['results'])
assert any(x.get('result',{}).get('workflowId') for x in out['v3-workflow-ungated']['results'])
pause_results=out['v3-pause']['results']
assert any(x.get('result',{}).get('state',{}).get('status')=='paused' for x in pause_results)
assert any(x.get('result',{}).get('state',{}).get('status')=='completed' for x in pause_results)
paused=next(x['result']['state'] for x in pause_results if x.get('result',{}).get('state',{}).get('status')=='paused')
completed=next(x['result']['state'] for x in pause_results if x.get('result',{}).get('state',{}).get('status')=='completed')
assert paused['root']['children'][0]['sessionId']==completed['root']['children'][0]['sessionId']
print(json.dumps({n:{'requests':len(v['requests']),'tools':v['toolNames'],'errors':[x['error']['code'] for x in v['errors']],'processExit':v['exit']['exit']} for n,v in out.items()},indent=2))
