import http.server, json, sys, os, itertools, threading
port=int(sys.argv[1]); out=sys.argv[2]; spawns=json.loads(open(sys.argv[3]).read())
n=itertools.count(); lock=threading.Lock()
def sse(events):
    s=""
    for e in events: s+=f"event: {e['type']}\ndata: {json.dumps(e)}\n\n"
    return s.encode()
def created(i): return {"type":"response.created","response":{"id":i}}
def done(i): return {"type":"response.completed","response":{"id":i,"usage":{"input_tokens":0,"input_tokens_details":None,"output_tokens":0,"output_tokens_details":None,"total_tokens":0}}}
def msg(i,t): return {"type":"response.output_item.done","item":{"type":"message","role":"assistant","id":"m"+i,"content":[{"type":"output_text","text":t}]}}
def call(cid,name,args): return {"type":"response.output_item.done","item":{"type":"function_call","call_id":cid,"name":name,"namespace":"collaboration","arguments":json.dumps(args)}}
def texts(body):
    for it in body.get("input",[]):
        if it.get("type")=="message":
            for c in it.get("content",[]): yield it.get("role"), c.get("text","")
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        l=int(self.headers.get('content-length',0)); raw=self.rfile.read(l)
        try: body=json.loads(raw)
        except Exception: body={}
        i=next(n); rid=f"resp_{i}"
        is_child=any(r=="developer" and t.startswith("<multi_agent_role>You are an agent") for r,t in texts(body))
        outs=[it for it in body.get("input",[]) if it.get("type")=="function_call_output"]
        calls=[it for it in body.get("input",[]) if it.get("type")=="function_call"]
        label="child" if is_child else "root"
        if is_child: ev=[created(rid),msg(rid,"CHILD DONE"),done(rid)]
        elif not calls and spawns: ev=[created(rid)]+[call(f"call_spawn_{k}","spawn_agent",a) for k,a in enumerate(spawns)]+[done(rid)]; label+="-spawn"
        elif not any(c.get("name")=="wait_agent" for c in calls): ev=[created(rid),call("call_wait","wait_agent",{"timeout_ms":15000}),done(rid)]; label+="-wait"
        elif spawns or calls: ev=[created(rid),msg(rid,"ROOT DONE"),done(rid)]; label+="-final"
        else: ev=[created(rid),msg(rid,"{\"findings\":[],\"overall_correctness\":\"patch is correct\",\"overall_explanation\":\"ok\",\"overall_confidence_score\":0.5}"),done(rid)]; label+="-plain"
        open(os.path.join(out,f"req{i:02d}-{label}.json"),"wb").write(raw)
        self.send_response(200); self.send_header('content-type','text/event-stream'); self.end_headers()
        self.wfile.write(sse(ev))
    def do_GET(self):
        self.send_response(404); self.end_headers()
    def log_message(self,*a): pass
http.server.ThreadingHTTPServer(("127.0.0.1",port),H).serve_forever()
