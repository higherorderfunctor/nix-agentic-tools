import json,os,queue,subprocess,sys,threading,time
cfg=json.load(open(sys.argv[1])); p=subprocess.Popen(sys.argv[2:],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(os.environ['ACP_STDERR'],'w'),text=True,bufsize=1)
log=open(os.environ['ACP_LOG'],'w'); q=queue.Queue(); msgs=[]; nid=0; wf=None
lock=threading.Lock()
def send(m):
 with lock:
  log.write('>> '+json.dumps(m)+'\n');log.flush();p.stdin.write(json.dumps(m)+'\n');p.stdin.flush()
def read():
 for line in p.stdout:
  log.write('<< '+line);log.flush()
  try:q.put(json.loads(line))
  except ValueError:pass
threading.Thread(target=read,daemon=True).start()
def drain(timeout=.05):
 try:m=q.get(timeout=timeout)
 except queue.Empty:return None
 msgs.append(m)
 if m.get('id') is not None and m.get('method'):
  if 'permission' in m['method']:
   opts=m.get('params',{}).get('options',[]); desired=cfg.get('permission','reject')
   pick=next((o['optionId'] for o in opts if str(o.get('kind','')).startswith(desired)),None)
   result={'outcome':{'outcome':'selected','optionId':pick}} if pick else {'outcome':{'outcome':'cancelled'}}
  else: result={}
  send({'jsonrpc':'2.0','id':m['id'],'result':result})
 return m
def start(method,params):
 global nid
 nid+=1;send({'jsonrpc':'2.0','id':nid,'method':method,'params':params});return nid
def wait(i,timeout=15):
 end=time.monotonic()+timeout
 while time.monotonic()<end:
  for m in msgs:
   if m.get('id')==i and ('result' in m or 'error' in m): return m
  drain()
 return {'timeout':i}
def call(method,params):
 r=wait(start(method,params));print(method,json.dumps(r)[:1500],flush=True);return r
call('initialize',{'protocolVersion':1,'clientInfo':{'name':cfg.get('client','probe'),'version':'0'},'clientCapabilities':{'fs':{'readTextFile':False,'writeTextFile':False},'terminal':False,'_meta':{'kiro':{'settings':cfg.get('initSettings',{}),'hooks':{'enabled':True,'v2':True}}}}})
r=call('session/new',{'cwd':os.getcwd(),'mcpServers':[],**cfg.get('new',{})});sid=r.get('result',{}).get('sessionId')
for step in cfg.get('steps',[]):
 params=json.loads(json.dumps(step.get('params',{})).replace('$SID',sid or '').replace('$WF',wf or ''))
 if step.get('event'):
  end=time.monotonic()+step.get('seconds',10)
  while time.monotonic()<end and not any(step['event'] in json.dumps(m) for m in msgs):drain()
  print('event',step['event'],any(step['event'] in json.dumps(m) for m in msgs),flush=True)
 elif step.get('sleep'):
  end=time.monotonic()+step['sleep']
  while time.monotonic()<end:drain()
 elif step.get('async'):globals()[step['async']]=start(step['method'],params)
 elif step.get('wait'):print('wait',step['wait'],json.dumps(wait(globals()[step['wait']])),flush=True)
 elif step.get('notify'):send({'jsonrpc':'2.0','method':step['method'],'params':params})
 else:
  result=call(step['method'],params)
  wf=result.get('result',{}).get('workflowId',wf)
p.stdin.close()
try:p.wait(timeout=3)
except subprocess.TimeoutExpired:p.kill();p.wait()
