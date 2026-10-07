import json, os, pathlib, shutil, subprocess, sys, time
# codex:R2-R4 — one case from cases/<name>.json against the pinned kiro-cli-chat in an empty netns.
# usage: [KIRO_BASE_HOME=<fixture home>] python3 offline.py <name>   → <work>/runs/<name>/
# work = $KIRO_CODEX_WORK, else $PROBE_OUT/kiro-codex, else a fresh temp dir (exported to the --inner child).
S=pathlib.Path(__file__).resolve().parent
sys.path.insert(0,str(S.parents[1]/'common'))
import pin  # noqa: E402
sys.path.insert(0, str(S.parent))
from fixture_home import create_home, service_settings  # noqa: E402
if '--inner' not in sys.argv:
    os.environ.setdefault('KIRO_CODEX_WORK',str(pin.workdir('kiro-codex')))
    os.environ.setdefault('KIRO_PKG',str(pin.package('kiro-cli.unwrapped')))
PRIOR=os.environ.get('KIRO_BASE_HOME')
U=pathlib.Path(os.environ['KIRO_PKG'])/'bin'
name=sys.argv[1]; cfg=json.loads((S/'cases'/(name+'.json')).read_text())
if 'rulesFrom' in cfg: cfg['rules']=json.loads((S/'cases'/(cfg['rulesFrom']+'.json')).read_text())['rules']
R=pathlib.Path(os.environ['KIRO_CODEX_WORK'])/'runs'/name
if '--inner' not in sys.argv:
    if R.exists(): shutil.rmtree(R)
    (R/'ws').mkdir(parents=True)
    if PRIOR: shutil.copytree(PRIOR,R/'home',symlinks=True)
    else: create_home(R/'home')
    settings=service_settings()
    settings.update(cfg.get('settings',{})); (R/'home/.kiro/settings/cli.json').write_text(json.dumps(settings))
    for agent in cfg.get('agents',[]):
        d=R/'home/.kiro/agents'; d.mkdir(parents=True,exist_ok=True); (d/(agent['name']+'.json')).write_text(json.dumps(agent))
    (R/'rules.json').write_text(json.dumps(cfg['rules']))
    result=subprocess.run(['unshare','-rn',sys.executable,__file__,name,'--inner'],timeout=55)
    print(f'run: {R}')
    (R/'exit.json').write_text(json.dumps({'exit':result.returncode})); sys.exit(result.returncode)
subprocess.run(['ip','link','set','lo','up'],check=True)
env={'PATH':str(U)+':/usr/bin:/bin','HOME':str(R/'home'),'CFFIXED_USER_HOME':str(R/'home'),'XDG_CONFIG_HOME':str(R/'home/.config'),'XDG_CACHE_HOME':str(R/'home/.cache'),'XDG_DATA_HOME':str(R/'home/.local/share'),'TERM':'dumb','KIRO_DISABLE_TELEMETRY':'1','KIRO_LOG_LEVEL':'debug','KIRO_CHAT_LOG_FILE':str(R/'chat.log'),'ACP_LOG':str(R/'acp.jsonl'),'ACP_STDERR':str(R/'acp.err')}
server=subprocess.Popen([sys.executable,str(S/'capserver.py'),'18765',str(R/'wire.jsonl')],env={**os.environ,'RULES':str(R/'rules.json')})
time.sleep(.4)
cmd=[str(U/'kiro-cli-chat'),*cfg['args']]
if cfg.get('acp'): cmd=[sys.executable,str(S/'driver.py'),str(S/'cases'/(name+'.json')),*cmd]
try:
    with (R/'out.txt').open('w') as f: result=subprocess.run(cmd,cwd=R/'ws',env=env,stdout=f,stderr=subprocess.STDOUT,timeout=45)
    sys.exit(result.returncode)
finally:
    server.terminate(); server.wait()
