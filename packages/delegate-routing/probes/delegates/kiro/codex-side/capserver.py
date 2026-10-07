import http.server,json,sys,struct,zlib,threading,os,time
# Capture server. Logs every request to argv[2]. ListAvailableModels -> one fixture model.
# GenerateAssistantResponse -> if $RULES (json list of {"match":str|null,"events":[...]}) has an unused rule
# whose match is in the body, answer with an AWS event stream built from its events; else 400.
OUT=sys.argv[2]; RULES=json.load(open(os.environ['RULES'])) if os.environ.get('RULES') else []
used=set(); lock=threading.Lock()
M={"modelId":"claude-sonnet-4","modelName":"Claude Sonnet 4","description":"fixture","tokenLimits":{"maxInputTokens":200000,"maxOutputTokens":64000},"supportedInputTypes":["TEXT"],"rateMultiplier":1.0,"rateUnit":"credit"}
def hdr(n,v):
    n=n.encode(); v=v.encode(); return bytes([len(n)])+n+b'\x07'+struct.pack('>H',len(v))+v
def msg(etype,payload):
    h=hdr(':message-type','event')+hdr(':event-type',etype)+hdr(':content-type','application/json')
    p=json.dumps(payload).encode(); total=12+len(h)+len(p)+4
    pre=struct.pack('>II',total,len(h)); pre+=struct.pack('>I',zlib.crc32(pre))
    body=pre+h+p; return body+struct.pack('>I',zlib.crc32(body))
def stream(events):
    out=b''
    for e in events:
        if isinstance(e,str): out+=msg('assistantResponseEvent',{"content":e})
        else: out+=msg('toolUseEvent',{"toolUseId":e["toolUseId"],"name":e["name"],"input":json.dumps(e["input"])}); out+=msg('toolUseEvent',{"toolUseId":e["toolUseId"],"name":e["name"],"stop":True})
    out+=msg('metadataEvent',{"stopReason":"TOOL_USE" if any(not isinstance(e,str) for e in events) else "END_TURN"})
    return out
class H(http.server.BaseHTTPRequestHandler):
    protocol_version='HTTP/1.1'
    def do_POST(self):
        n=int(self.headers.get('content-length',0)); body=self.rfile.read(n); text=body.decode('utf-8','replace')
        t=self.headers.get('x-amz-target') or ''
        rule=None
        if 'GenerateAssistantResponse' in t:
            with lock:
                for i,r in enumerate(RULES):
                    if i in used: continue
                    mm=r.get('match'); mm=[] if mm is None else ([mm] if isinstance(mm,str) else mm)
                    if all(x in text for x in mm) and not any(x in text for x in r.get('not',[])): used.add(i); rule=i; break
        with open(OUT,'a') as f:
            f.write(json.dumps({'method':self.command,'path':self.path,'target':t,'rule':rule,'headers':dict(self.headers),'body':text})+'\n')
        try:
            if 'ListAvailableModels' in t:
                out=json.dumps({"models":[M,{**M,"modelId":"claude-haiku-4.5","modelName":"Claude Haiku 4.5"}],"defaultModel":M}).encode(); code=200; ct='application/x-amz-json-1.0'
            elif rule is not None:
                time.sleep(RULES[rule].get('delay',0)); out=stream(RULES[rule]['events']); code=200; ct='application/vnd.amazon.eventstream'
            else:
                out=b'{"__type":"ValidationException","message":"capture-server"}'; code=400; ct='application/x-amz-json-1.0'
            self.send_response(code); self.send_header('content-type',ct); self.send_header('content-length',str(len(out))); self.end_headers(); self.wfile.write(out)
        except BrokenPipeError: pass
    do_GET=do_POST
    def log_message(self,*a): pass
http.server.ThreadingHTTPServer(('127.0.0.1',int(sys.argv[1])),H).serve_forever()
