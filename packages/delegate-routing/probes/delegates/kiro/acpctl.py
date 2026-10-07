import json,subprocess,sys,threading,time,os,queue
# ACP stdio driver with timed steps. Usage: acpctl.py <script.json> <binary> <args...>
# script: {"capsMeta":{initialize clientCapabilities._meta, e.g. {"kiro":{"settings":{..}}}}, "initMeta":{...}, "new":{session/new params minus cwd}, "permission":"allow"|"reject"|"cancelled" or {"<substring of toolCall json>":action,"*":default},
#          "steps":[{"op":"prompt","text":..,"async":bool,"tag":..} | {"op":"wait","tag":..,"timeout":s} |
#                   {"op":"sleep","s":n} | {"op":"notify","method":..,"params":{..}} | {"op":"call","method":..,"params":{..}}]}
# {"op":"grab","method":<notification>,"path":"params.x.0.y","as":"NAME"} saves a field of the last such notification.
# {"op":"call",...,"save":{"NAME":"result.runs.0.workflowId"}} stores a value for later "$NAME" substitution.
# "$SID" in params is replaced by the session id, "$CWD" by the working directory. Every frame is logged to $ACP_LOG with a relative timestamp.
# Permission action "ignore" never answers the request. "replies":{"<method>":<result>|"ignore"} answers other
# agent->client requests (default {}). A prompt step may carry "meta" (session/prompt _meta). {"op":"sh","cmd":..}
# runs a shell command in the cwd (the run's ws) between steps. "permissionVia":"respond" answers a permission
# request with a _kiro/permission/respond request instead of a JSON-RPC reply (the `serve` mux discards those).
script=json.load(open(sys.argv[1])); cmd=sys.argv[2:]; T0=time.time()
p=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=open(os.environ.get('ACP_STDERR','/dev/null'),'w'),text=True,bufsize=1)
log=open(os.environ['ACP_LOG'],'w'); results={}; lastnote={}; waiters={}; lock=threading.Lock(); perm=script.get('permission','allow'); replies=script.get('replies',{})
def ts(): return f"{time.time()-T0:7.2f}"
def send(m):
    with lock:
        log.write(ts()+' >> '+json.dumps(m)+'\n'); log.flush(); p.stdin.write(json.dumps(m)+'\n'); p.stdin.flush()
def rd():
    for line in p.stdout:
        log.write(ts()+' << '+line); log.flush()
        try: m=json.loads(line)
        except Exception: continue
        if 'id' in m and ('result' in m or 'error' in m):
            results[m['id']]=m
        elif 'method' in m and 'id' not in m:
            lastnote[m['method']]=m
        elif 'method' in m and 'id' in m:
            meth=m['method']; res=replies.get(meth,{})
            if res=='ignore':
                log.write(ts()+f' ## {meth} -> no reply\n'); continue
            if 'permission' in meth:
                opts=(m.get('params') or {}).get('options') or []
                title=json.dumps((m.get('params') or {}).get('toolCall',{}))
                act=perm if isinstance(perm,str) else next((v for k,v in perm.items() if k!='*' and k in title),perm.get('*','allow'))
                log.write(ts()+f' ## permission policy -> {act}\n')
                if act=='ignore': continue
                if act=='cancelled': res={"outcome":{"outcome":"cancelled"}}
                else:
                    kind='allow' if act=='allow' else 'reject'
                    pick=next((o['optionId'] for o in opts if str(o.get('kind','')).startswith(kind)),None) or (opts[0]['optionId'] if opts else kind)
                    res={"outcome":{"outcome":"selected","optionId":pick}}
                    if script.get('permissionVia')=='respond':
                        tc=((m.get('params') or {}).get('toolCall') or {}).get('toolCallId')
                        send({"jsonrpc":"2.0","id":f"pr-{m['id']}","method":"_kiro/permission/respond","params":{"toolCallId":tc,"optionId":pick}}); continue
            send({"jsonrpc":"2.0","id":m['id'],"result":res})
threading.Thread(target=rd,daemon=True).start()
nid=[0]
def req(method,params):
    nid[0]+=1; i=nid[0]; send({"jsonrpc":"2.0","id":i,"method":method,"params":params}); return i
def wait(i,timeout):
    end=time.time()+timeout
    while time.time()<end:
        if i in results: return results[i]
        time.sleep(0.2)
    return {'timeout':i}
r=wait(req('initialize',{"protocolVersion":1,"clientCapabilities":{"fs":{"readTextFile":False,"writeTextFile":False},"terminal":False,**({"_meta":script["capsMeta"]} if "capsMeta" in script else {})},"clientInfo":{"name":script.get('clientName','probe'),"version":"0"},**({"_meta":script['initMeta']} if 'initMeta' in script else {})}),60)
print(ts(),'init',json.dumps(r)[:300],flush=True)
newp={"cwd":os.getcwd(),"mcpServers":[]}; newp.update(script.get('new',{}))
r=wait(req('session/new',newp),180); print(ts(),'new',json.dumps(r)[:500],flush=True)
sid=(r.get('result') or {}).get('sessionId') or ''
saved={}
def sub(o):
    t=json.dumps(o).replace('$SID',sid).replace('$CWD',os.getcwd())
    for k,v in saved.items(): t=t.replace('$'+k,str(v))
    return json.loads(t)
def dig(o,path):
    for part in path.replace(']','').replace('[','.').split('.'):
        o=o[int(part)] if part.isdigit() else o[part]
    return o
tags={}
for st in script.get('steps',[]):
    op=st['op']
    if op=='prompt':
        i=req('session/prompt',{"sessionId":sid,"prompt":[{"type":"text","text":st['text']}],**({"_meta":st['meta']} if 'meta' in st else {})})
        if st.get('async'): tags[st.get('tag','p')]=i
        else: r=wait(i,st.get('timeout',180)); print(ts(),'prompt',json.dumps(r)[:400],flush=True)
    elif op=='wait': r=wait(tags[st['tag']],st.get('timeout',180)); print(ts(),'wait',st['tag'],json.dumps(r)[:400],flush=True)
    elif op=='sleep': time.sleep(st['s'])
    elif op=='sh': r=subprocess.run(['bash','-c',sub(st)['cmd']],capture_output=True,text=True); print(ts(),'sh',r.returncode,(r.stdout+r.stderr)[:1500],flush=True)
    elif op=='grab':
        try: saved[st['as']]=dig(lastnote[st['method']],st['path']); print(ts(),'grab',st['as'],saved[st['as']],flush=True)
        except Exception as e: print(ts(),'grab failed',st,e,flush=True)
    elif op=='notify': send({"jsonrpc":"2.0","method":st['method'],"params":sub(st.get('params',{}))}); print(ts(),'notify',st['method'],flush=True)
    elif op=='call':
        r=wait(req(st['method'],sub(st.get('params',{}))),st.get('timeout',60)); print(ts(),'call',st['method'],json.dumps(r)[:900],flush=True)
        for k,path in (st.get('save') or {}).items():
            try: saved[k]=dig(r,path)
            except Exception as e: print('save failed',k,e,flush=True)
p.stdin.close()
try: p.wait(timeout=10)
except Exception: p.kill()
