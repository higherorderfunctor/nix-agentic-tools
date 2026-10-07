#!/usr/bin/env python3
"""Ask pinned `claude mcp serve` for its MCP initialize and tool list."""
import json, os, pathlib, selectors, subprocess, time
import sys as _sys
_sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "common"))
import pin  # noqa: E402
root=pin.workdir("claude-host")  # runs/<case>/ land here
run=root/'runs'/'mcp-serve'
run.mkdir(parents=True,exist_ok=True)
env=dict(os.environ)
env.update({'CLAUDE_CONFIG_DIR':str(run/'config'),'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC':'1','DISABLE_AUTOUPDATER':'1'})
bin=os.environ.get('CLAUDE_BIN') or str(pin.package('claude-code')/'bin'/'claude')
proc=subprocess.Popen([bin,'mcp','serve'],cwd=run,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
sel=selectors.DefaultSelector();sel.register(proc.stdout,selectors.EVENT_READ)
def send(obj): proc.stdin.write(json.dumps(obj)+'\n');proc.stdin.flush()
def recv(timeout=15):
 if not sel.select(timeout): return None
 line=proc.stdout.readline()
 try:return json.loads(line)
 except json.JSONDecodeError:return {'raw':line[:300]}
send({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'offline-probe','version':'1'}}})
init=recv()
if init is not None: send({'jsonrpc':'2.0','method':'notifications/initialized','params':{}})
send({'jsonrpc':'2.0','id':2,'method':'tools/list','params':{}})
listed=recv()
proc.stdin.close()
try:proc.wait(timeout=5)
except subprocess.TimeoutExpired:proc.terminate();proc.wait(timeout=2)
try:err=proc.stderr.read()
except Exception:err=''
transcript={'command':[bin,'mcp','serve'],'initialize':init,'tools_list':listed,'stderr':err,'exit_code':proc.returncode}
(run/'transcript.json').write_text(json.dumps(transcript,indent=2)+'\n')
tools=(listed or {}).get('result',{}).get('tools',[])
summary=[]
for name in ('Agent','Workflow','TaskStop','ListAgents','SendMessage'):
    tool=next((x for x in tools if x.get('name')==name),None)
    if tool:
        schema=tool.get('inputSchema') or tool.get('input_schema') or {}
        summary.append({'name':name,'description':tool.get('description','')[:1000],
            'required':schema.get('required',[]),'properties':schema.get('properties',{})})
(run/'schema-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print('initialize',init.get('result',{}).get('serverInfo') if init else None)
result=(listed or {}).get('result',{})
print('tools',[(x.get('name'),x.get('description','')[:120]) for x in result.get('tools',[])])
print('exit',proc.returncode,'stderr',err[:300])
print(f'run: {root / "runs" / "mcp-serve"}')
