#!/usr/bin/env python3
"""Invoke advertised Agent once via MCP against a deterministic loopback model."""
import json, os, pathlib, queue, subprocess, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import sys as _sys
_sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "common"))
import pin  # noqa: E402
root=pin.workdir("claude-host")  # runs/<case>/ land here
run=root/'runs'/'mcp-agent-call';run.mkdir(parents=True,exist_ok=True)
requests=[]
class API(BaseHTTPRequestHandler):
    def log_message(self,*_): pass
    def do_POST(self):
        body=json.loads(self.rfile.read(int(self.headers.get('Content-Length',0))))
        requests.append({'path':self.path,'model':body.get('model'),'stream':body.get('stream'),'output_config':body.get('output_config'),'tool_names':[t.get('name') for t in body.get('tools',[])]})
        if 'count_tokens' in self.path:
            self._json({'input_tokens':100});return
        content=[{'type':'text','text':'CAPTURE_COMPLETE'}]
        msg={'id':'msg_capture','type':'message','role':'assistant','model':body.get('model','claude-haiku-4-5-20251001'),'content':content,'stop_reason':'end_turn','stop_sequence':None,'usage':{'input_tokens':100,'output_tokens':2}}
        if body.get('stream'):
            self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
            def ev(name,value): self.wfile.write(('event: '+name+'\ndata: '+json.dumps(value)+'\n\n').encode());self.wfile.flush()
            ev('message_start',{'type':'message_start','message':{**msg,'content':[],'stop_reason':None,'usage':{'input_tokens':100,'output_tokens':0}}})
            ev('content_block_start',{'type':'content_block_start','index':0,'content_block':{'type':'text','text':''}})
            ev('content_block_delta',{'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'CAPTURE_COMPLETE'}})
            ev('content_block_stop',{'type':'content_block_stop','index':0})
            ev('message_delta',{'type':'message_delta','delta':{'stop_reason':'end_turn','stop_sequence':None},'usage':{'output_tokens':2}})
            ev('message_stop',{'type':'message_stop'})
        else:self._json(msg)
    def _json(self,obj):
        payload=json.dumps(obj).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(payload)));self.end_headers();self.wfile.write(payload)
api=ThreadingHTTPServer(('127.0.0.1',18767),API);threading.Thread(target=api.serve_forever,daemon=True).start()
env=dict(os.environ);env.update({'CLAUDE_CONFIG_DIR':str(run/'config'),'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC':'1','DISABLE_AUTOUPDATER':'1','ANTHROPIC_BASE_URL':'http://127.0.0.1:18767','ANTHROPIC_API_KEY':'offline-capture-key'})
bin=os.environ.get('CLAUDE_BIN') or str(pin.package('claude-code')/'bin'/'claude')
proc=subprocess.Popen([bin,'mcp','serve'],cwd=run,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,bufsize=1)
q=queue.Queue()
def read():
    for line in proc.stdout:q.put(line.rstrip('\n'))
threading.Thread(target=read,daemon=True).start()
def send(o):proc.stdin.write(json.dumps(o)+'\n');proc.stdin.flush()
def until_id(target,timeout=45):
    deadline=time.monotonic()+timeout;seen=[]
    while time.monotonic()<deadline:
        try:line=q.get(timeout=.25)
        except queue.Empty:
            if proc.poll() is not None:break
            continue
        try:o=json.loads(line)
        except json.JSONDecodeError:continue
        seen.append(o)
        if o.get('id')==target:return seen,o
    return seen,None
send({'jsonrpc':'2.0','id':1,'method':'initialize','params':{'protocolVersion':'2025-06-18','capabilities':{},'clientInfo':{'name':'offline-probe','version':'1'}}})
_,init=until_id(1)
send({'jsonrpc':'2.0','method':'notifications/initialized','params':{}})
send({'jsonrpc':'2.0','id':2,'method':'tools/call','params':{'name':'Agent','arguments':{'description':'offline probe','prompt':'Return exactly CAPTURE_COMPLETE. Do not use tools.','model':'haiku','name':'offline-probe','mode':'dontAsk'}}})
seen,result=until_id(2)
proc.stdin.close()
try:proc.wait(timeout=10)
except subprocess.TimeoutExpired:proc.terminate();proc.wait(timeout=3)
err=proc.stderr.read()
payload=None
if result:
    raw=(result.get('result',{}).get('content') or [{}])[0].get('text')
    try: payload=json.loads(raw)
    except (json.JSONDecodeError,TypeError): payload={'raw_text':raw}
if isinstance(payload,dict): payload.pop('agentId',None)
summary={'initialize_server':(init or {}).get('result',{}).get('serverInfo'),
    'tool_call_id':2,'status':payload.get('status') if isinstance(payload,dict) else None,
    'agentType':payload.get('agentType') if isinstance(payload,dict) else None,
    'resolvedModel':payload.get('resolvedModel') if isinstance(payload,dict) else None,
    'totalToolUseCount':payload.get('totalToolUseCount') if isinstance(payload,dict) else None,
    'content':payload.get('content') if isinstance(payload,dict) else payload,
    'usage':payload.get('usage') if isinstance(payload,dict) else None,
    'model_requests':requests,'stderr':err,'server_exit_after_harness_shutdown':proc.returncode}
(run/'transcript.json').write_text(json.dumps(summary,indent=2)+'\n')
print('initialize_ok',bool(init and 'result' in init),'tool_call_returned',result is not None,'model_requests',len(requests),'exit',proc.returncode,'stderr',err[:200])
if result:print('tool_result',json.dumps(result)[:1300])
api.shutdown()
print(f'run: {root / "runs" / "mcp-agent-call"}')
