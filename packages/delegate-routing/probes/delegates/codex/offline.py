import gzip
import http.server
import json
import os
import pathlib
import queue
import shutil
import subprocess
import sys
import threading
import time

# codex:R1 — `codex exec` native delegate cases against a loopback provider.
# usage: python3 offline.py [<case>...]   (no case = all); writes <work>/offline/<case>/
# work = $PROBE_OUT/codex-offline or a fresh temp dir (printed at the end).
S = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(S))
import codexpin  # noqa: E402
B = codexpin.binary()
WORK = codexpin.workdir('codex-offline')
PRIOR = codexpin.models_cache(WORK)
OUT = WORK / 'offline'
OUT.mkdir(exist_ok=True)
state = {}
lock = threading.Lock()

def messages(body):
    return '\n'.join(c.get('text', '') for it in body.get('input', []) if it.get('type') == 'message' for c in it.get('content', []))

def outputs(body):
    return [it for it in body.get('input', []) if it.get('type') == 'function_call_output']

def emit_call(name, args, ident, v1=False):
    return dict(type='response.output_item.done', item=dict(type='function_call', call_id=ident, name=name, namespace='multi_agent_v1' if v1 else 'collaboration', arguments=json.dumps(args)))

def emit_message(text, ident):
    return dict(type='response.output_item.done', item=dict(type='message', role='assistant', id='m' + ident, content=[dict(type='output_text', text=text)]))

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"models":[]}')
    def do_POST(self):
        raw = self.rfile.read(int(self.headers['Content-Length']))
        if self.headers.get('Content-Encoding') == 'gzip':
            raw = gzip.decompress(raw)
        elif self.headers.get('Content-Encoding') == 'zstd':
            raw = subprocess.run(['zstd', '-d', '-q'], input=raw, capture_output=True, check=True).stdout
        body = json.loads(raw)
        with lock:
            case = state['case']
            ident = str(len(state['requests']))
            state['requests'].append(dict(path=self.path, body=body))
        text = messages(body)
        is_child = '<multi_agent_role>You are an agent' in text or (state.get('v1') and any(marker in text for marker in ['CHILD_PROBE', 'GRANDCHILD_PROBE', 'FOLLOWUP_PROBE', 'RESUMED_PROBE']))
        outs = outputs(body)
        # Every first child can make one nested spawn in nesting cases.
        if is_child:
            if state.get('nested') and 'GRANDCHILD_PROBE' not in json.dumps(body.get('input', [])) and not outs:
                args = dict(message='GRANDCHILD_PROBE', fork_context=False) if state.get('v1') else dict(task_name='grand', message='GRANDCHILD_PROBE', fork_turns='none')
                item = emit_call('spawn_agent', args, 'nested', state.get('v1'))
            else:
                item = emit_message('GRAND_DONE' if 'GRANDCHILD_PROBE' in text else 'CHILD_DONE', ident)
                time.sleep(2 if state['case'] in {'v2-running-interrupt', 'v2-interrupt-tree', 'v2-concurrency'} else 0.06)
        else:
            n = len(outs)
            if n < len(state['actions']):
                name, args = state['actions'][n]
                args = json.loads(json.dumps(args))
                if '$ID' in json.dumps(args):
                    found = next((json.loads(o['output']).get('agent_id') for o in outs if isinstance(o.get('output'), str) and 'agent_id' in o['output']), None)
                    args = json.loads(json.dumps(args).replace('$ID', found or 'invalid'))
                item = emit_call(name, args, 'action_' + str(n), state.get('v1'))
            else:
                item = emit_message('ROOT_DONE', ident)
        rid = 'resp_' + ident
        evs = [dict(type='response.created', response=dict(id=rid)), item, dict(type='response.completed', response=dict(id=rid, usage=dict(input_tokens=0, output_tokens=0, total_tokens=0)))]
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        try:
            for ev in evs:
                self.wfile.write(('event: ' + ev['type'] + '\ndata: ' + json.dumps(ev) + '\n\n').encode())
        except (BrokenPipeError, ConnectionResetError):
            pass

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), H)
threading.Thread(target=server.serve_forever, daemon=True).start()
common = ['-c', 'model_provider="probe"', '-c', 'model_providers.probe.name="Probe"', '-c', f'model_providers.probe.base_url="http://127.0.0.1:{server.server_port}/v1"', '-c', 'model_providers.probe.wire_api="responses"', '-c', 'model_providers.probe.requires_openai_auth=false', '-c', 'model_providers.probe.supports_websockets=false', '-c', 'project_root_markers=[".probe-root"]', '-c', 'features.shell_tool=false', '-c', 'features.memories=false', '-c', 'features.code_mode=false']

def run_case(name, actions, extra=(), v1=False, nested=False):
    global state
    if sys.argv[1:] and name not in sys.argv[1:]:
        return
    root = OUT / name
    home = root / 'home'
    cwd = root / 'work'
    home.mkdir(parents=True, exist_ok=True)
    cwd.mkdir(exist_ok=True)
    (cwd / '.probe-root').touch()
    if name == 'piD6':
        (cwd / 'AGENTS.md').write_text('UNTRUSTED-AGENTS-8006\n')
        (cwd / '.codex').mkdir(exist_ok=True)
        (cwd / '.codex' / 'config.toml').write_text('developer_instructions = "UNTRUSTED-PROJ-8005"\n')
    cache = json.loads(PRIOR.read_text())
    for m in cache['models']:
        if v1:
            m['multi_agent_version'] = 'v1'
    (home / 'models_cache.json').write_text(json.dumps(cache))
    if v1:
        catalog = root / 'catalog.json'
        catalog.write_text(json.dumps(dict(models=cache['models'])))
        extra = [*extra, '-c', f'model_catalog_json="{catalog}"', '-c', 'features.multi_agent=true', '-c', 'features.multi_agent_v2=false']
    else:
        extra = ['-c', 'features.multi_agent_v2.enabled=true', '-c', 'features.multi_agent_v2.expose_spawn_agent_model_overrides=true', '-c', 'features.multi_agent_v2.min_wait_timeout_ms=0', '-c', 'features.multi_agent_v2.default_wait_timeout_ms=100', '-c', 'features.multi_agent_v2.max_wait_timeout_ms=1000', *extra]
    state = dict(case=name, requests=[], actions=actions, v1=v1, nested=nested)
    argv = [B, 'exec', '--model', 'gpt-6-luna', '-c', 'model_reasoning_effort="low"', '--skip-git-repo-check', '--json', *common, *extra, '-']
    env = dict(os.environ, CODEX_HOME=str(home))
    (root / 'command.json').write_text(json.dumps(dict(argv=argv, cwd=str(cwd), CODEX_HOME=str(home), stdin='ROOT_PROBE'), indent=2))
    r = subprocess.run(argv, input='ROOT_PROBE', cwd=cwd, env=env, capture_output=True, text=True, timeout=40)
    (root / 'stdout.jsonl').write_text(r.stdout)
    (root / 'stderr.txt').write_text(r.stderr)
    reqs = list(state['requests'])
    if name == 'piD6':
        wire_text = '\n'.join(messages(r['body']) for r in reqs)
        assert r.returncode == 0, r.stderr
        assert 'UNTRUSTED-AGENTS-8006' in wire_text, 'unknown trust must load AGENTS.md'
        assert 'UNTRUSTED-PROJ-8005' not in wire_text, 'unknown trust must skip project config'
        print('piD6: UNTRUSTED-AGENTS-8006 present; UNTRUSTED-PROJ-8005 absent')
    (root / 'requests.json').write_text(json.dumps(reqs, indent=2))
    summary = dict(case=name, exit=r.returncode, requests=len(reqs), wire=[dict(model=x['body'].get('model'), effort=x['body'].get('reasoning', {}).get('effort'), child='<multi_agent_role>You are an agent' in messages(x['body']), outputs=outputs(x['body'])) for x in reqs])
    (root / 'summary.json').write_text(json.dumps(summary, indent=2))
    if name == 'exec-resume-fork':
        tid = next(json.loads(line)['thread_id'] for line in r.stdout.splitlines() if json.loads(line).get('type') == 'thread.started')
        for op in ['resume', 'fork']:
            state['requests'] = []
            cmd = [B, 'exec', op, *argv[2:-1], '-c', 'model_reasoning_effort="medium"', '--output-last-message', str(root / (op + '.last.txt')), tid, '-']
            result = subprocess.run(cmd, input='CONTINUE_' + op, cwd=cwd, env=env, text=True, capture_output=True, timeout=40)
            (root / (op + '.command.json')).write_text(json.dumps(dict(argv=cmd, cwd=str(cwd), CODEX_HOME=str(home), stdin='CONTINUE_' + op), indent=2))
            (root / (op + '.stdout.jsonl')).write_text(result.stdout)
            (root / (op + '.stderr.txt')).write_text(result.stderr)
            (root / (op + '.requests.json')).write_text(json.dumps(state['requests'], indent=2))
            assert result.returncode == 0, result.stderr
    print(json.dumps(summary), flush=True)

try:
    spawn = dict(task_name='child', message='CHILD_PROBE', fork_turns='none', model='gpt-6-luna', reasoning_effort='low')
    run_case('v2-lifecycle', [('spawn_agent', spawn), ('wait_agent', dict(timeout_ms=500)), ('list_agents', {}), ('send_message', dict(target='child', message='PASSIVE_MESSAGE')), ('followup_task', dict(target='child', message='FOLLOWUP_PROBE')), ('wait_agent', dict(timeout_ms=500)), ('interrupt_agent', dict(target='child')), ('list_agents', {})])
    run_case('v2-running-interrupt', [('spawn_agent', spawn), ('send_message', dict(target='child', message='MIDRUN_MESSAGE')), ('list_agents', {}), ('interrupt_agent', dict(target='child')), ('list_agents', {}), ('followup_task', dict(target='child', message='AFTER_INTERRUPT')), ('wait_agent', dict(timeout_ms=1000))])
    run_case('v2-interrupt-tree', [('spawn_agent', spawn), ('wait_agent', dict(timeout_ms=500)), ('list_agents', {}), ('interrupt_agent', dict(target='child')), ('list_agents', {})], nested=True)
    run_case('v2-concurrency', [('spawn_agent', dict(spawn, task_name='child' + str(i))) for i in range(4)] + [('list_agents', {})])
    evict_actions = []
    for i in range(3):
        evict_actions.extend([('spawn_agent', dict(spawn, task_name='child' + str(i))), ('wait_agent', dict(timeout_ms=500))])
    evict_actions.extend([('list_agents', {}), ('followup_task', dict(target='child0', message='RELOAD_OLDEST')), ('wait_agent', dict(timeout_ms=500))])
    run_case('v2-resident-eviction', evict_actions, ['-c', 'features.multi_agent_v2.max_concurrent_threads_per_session=2'])
    run_case('v1-close-tree', [('spawn_agent', dict(message='CHILD_PROBE')), ('wait_agent', dict(targets=['$ID'], timeout_ms=10000)), ('close_agent', dict(target='$ID'))], ['-c', 'agents.max_depth=2'], v1=True, nested=True)
    if not sys.argv[1:] or 'v2-role-model' in sys.argv[1:]:
        role_file = OUT / 'v2-role-model' / 'reader.toml'
        role_file.parent.mkdir(parents=True, exist_ok=True)
        role_file.write_text('model = "gpt-6-luna"\nmodel_reasoning_effort = "medium"\n')
        run_case('v2-role-model', [('spawn_agent', dict(spawn, agent_type='reader')), ('wait_agent', dict(timeout_ms=500))], ['-c', 'agents.reader.description="model pin probe"', '-c', f'agents.reader.config_file="{role_file}"'])
    run_case('exec-resume-fork', [])
    run_case('piD6', [])
    run_case('v2-full-model', [('spawn_agent', dict(spawn, fork_turns='all', reasoning_effort='medium')), ('wait_agent', dict(timeout_ms=500))])
    run_case('v2-lastn-model', [('spawn_agent', dict(spawn, fork_turns='1')), ('wait_agent', dict(timeout_ms=500))])
    run_case('v2-nested-depth-zero', [('spawn_agent', spawn), ('wait_agent', dict(timeout_ms=500)), ('list_agents', {})], ['-c', 'agents.max_depth=0'], nested=True)
    run_case('v2-invalid', [('spawn_agent', dict(spawn, model='NO_SUCH_MODEL')), ('spawn_agent', dict(spawn, reasoning_effort='ultra')), ('spawn_agent', dict(spawn, fork_turns='0')), ('wait_agent', dict(timeout_ms=1001))])
    run_case('disabled', [('spawn_agent', spawn)], ['-c', 'agents.enabled=false', '-c', 'features.multi_agent_v2.enabled=false'])
    run_case('v1-lifecycle', [('spawn_agent', dict(message='CHILD_PROBE', model='gpt-6-luna', reasoning_effort='low')), ('wait_agent', dict(targets=['$ID'], timeout_ms=10000)), ('send_input', dict(target='$ID', message='FOLLOWUP_PROBE')), ('wait_agent', dict(targets=['$ID'], timeout_ms=10000)), ('close_agent', dict(target='$ID')), ('resume_agent', dict(id='$ID')), ('send_input', dict(target='$ID', message='RESUMED_PROBE')), ('wait_agent', dict(targets=['$ID'], timeout_ms=10000))], v1=True)
    run_case('v1-nested-depth-one', [('spawn_agent', dict(message='CHILD_PROBE')), ('wait_agent', dict(targets=['$ID'], timeout_ms=10000))], v1=True, nested=True)
finally:
    server.shutdown()
print(f'work: {WORK}')
