import json,sys,glob,os,re
sent=re.compile(r"[A-Z]+(?:-[A-Z0-9]+)*-\d{4}")
for f in sorted(glob.glob(os.path.join(sys.argv[1],"req*.json"))):
    d=json.load(open(f)); inp=d.get("input",[])
    task=None; devs=[]; base=None; agents=None; ff=[]
    for k,it in enumerate(inp):
        if it.get("type")=="message":
            for c in it["content"]:
                t=c.get("text","")
                if it["role"]=="developer":
                    if k==1: base=t[:60]
                    devs.append((k,t[:45].replace("\n"," "),len(t)))
                if it["role"]=="user" and t.startswith("# AGENTS.md"): agents=len(t)
                if it["role"]=="user" and not t.startswith("# AGENTS.md") and not t.startswith("<environment"): task=t[:80]
        elif it.get("type")=="function_call_output": ff.append(it.get("output","")[:200])
    s=sorted(set(sent.findall(json.dumps(d))))
    print("==",os.path.basename(f),"| instr_field=",len(d.get("instructions") or ""),"| base@1=",repr(base),"| AGENTS.md=",agents,"| last user=",repr(task))
    print("   sentinels:",s)
    for x in devs: print("   dev",x)
    for o in ff: print("   fco:",o)
