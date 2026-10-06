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

# codex:R2 — app-server protocol execution (steer, settings update, resume, fork, review, interrupt).
# usage: python3 protocol.py [--without-live-switch]; writes <work>/protocol[-feature-off]/
# work = $PROBE_OUT/codex-protocol or a fresh temp dir.
S = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(S))
import codexpin  # noqa: E402
WORK = codexpin.workdir('codex-protocol')
O = WORK / ('protocol-feature-off' if '--without-live-switch' in sys.argv else 'protocol')
O.mkdir(exist_ok=True)
B = codexpin.binary()
home = O / 'home'
cwd = O / 'work'
home.mkdir(exist_ok=True)
cwd.mkdir(exist_ok=True)
(cwd / '.probe-root').touch()
shutil.copy(codexpin.models_cache(WORK), home / 'models_cache.json')
requests = []
transcript = []
rpcs = []
release = threading.Event()
received = threading.Event()
hold = threading.Event()

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
        i = len(requests)
        requests.append(dict(path=self.path, body=body))
        was_hold = hold.is_set()
        if was_hold:
            hold.clear()
            received.set()
            release.wait(15)
            release.clear()
        rid = 'resp_' + str(i)
        if was_hold:
            item = dict(type='function_call', call_id='probe_wait_' + str(i), namespace='collaboration', name='wait_agent', arguments='{"timeout_ms":100}')
        else:
            item = dict(type='message', id='m' + str(i), role='assistant', content=[dict(type='output_text', text='PROTOCOL_DONE')])
        evs = [dict(type='response.created', response=dict(id=rid)), dict(type='response.output_item.done', item=item), dict(type='response.completed', response=dict(id=rid, usage=dict(input_tokens=0, output_tokens=0, total_tokens=0)))]
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
flags = ['model="gpt-6-luna"', 'model_reasoning_effort="low"', 'model_provider="probe"', 'model_providers.probe.name="Probe"', f'model_providers.probe.base_url="http://127.0.0.1:{server.server_port}/v1"', 'model_providers.probe.wire_api="responses"', 'model_providers.probe.requires_openai_auth=false', 'model_providers.probe.supports_websockets=false', 'project_root_markers=[".probe-root"]', 'features.shell_tool=false', 'features.memories=false', 'features.code_mode=false', 'features.step_model_switching=' + ('false' if '--without-live-switch' in sys.argv else 'true'), 'features.multi_agent_v2.enabled=true', 'features.multi_agent_v2.min_wait_timeout_ms=0', 'features.multi_agent_v2.default_wait_timeout_ms=100', 'features.multi_agent_v2.max_wait_timeout_ms=1000']
argv = [B, 'app-server', '--stdio', *[v for f in flags for v in ['-c', f]]]
(O / 'command.json').write_text(json.dumps(dict(argv=argv, cwd=str(cwd), CODEX_HOME=str(home)), indent=2))
err = (O / 'stderr.txt').open('w')
p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, text=True, cwd=cwd, env=dict(os.environ, CODEX_HOME=str(home)), bufsize=1)
q = queue.Queue()
def read():
    for line in p.stdout:
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        transcript.append(dict(direction='in', message=msg))
        q.put(msg)
threading.Thread(target=read, daemon=True).start()

def send(msg):
    transcript.append(dict(direction='out', message=msg))
    p.stdin.write(json.dumps(msg) + '\n')
    p.stdin.flush()

def rpc(method, params):
    ident = len(rpcs) + 1
    send(dict(id=ident, method=method, params=params))
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        msg = q.get(timeout=15)
        if msg.get('id') == ident:
            rpcs.append(dict(method=method, params=params, response=msg))
            print(method, 'ERROR' if 'error' in msg else 'OK', flush=True)
            return msg
    raise TimeoutError(method)

def done(tid, start):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        for entry in transcript[start:]:
            msg = entry['message']
            if entry['direction'] == 'in' and msg.get('method') == 'turn/completed' and msg['params']['threadId'] == tid:
                return msg
        time.sleep(0.01)
    raise TimeoutError('turn completed')

try:
    rpc('initialize', dict(clientInfo=dict(name='delegate_reference', version='1'), capabilities=dict(experimentalApi=True)))
    send(dict(method='initialized'))
    t = rpc('thread/start', dict(cwd=str(cwd), model='gpt-6-luna', modelProvider='probe', approvalPolicy='never', sandbox='read-only', ephemeral=False))['result']['thread']['id']
    hold.set()
    start = len(transcript)
    turn = rpc('turn/start', dict(threadId=t, input=[dict(type='text', text='RUNNING_PROBE')], effort='low'))['result']['turn']['id']
    assert received.wait(10)
    rpc('turn/steer', dict(threadId=t, expectedTurnId='wrong-id', input=[dict(type='text', text='BAD_STEER')]))
    rpc('turn/settings/update', dict(threadId=t, turnId=turn, model='gpt-6-luna', effort='medium'))
    rpc('turn/steer', dict(threadId=t, expectedTurnId=turn, input=[dict(type='text', text='STEER_PROBE')]))
    release.set()
    done(t, start)
    rpc('thread/read', dict(threadId=t, includeTurns=True))
    rpc('thread/loaded/list', {})
    rpc('thread/settings/update', dict(threadId=t, effort='low'))
    start = len(transcript)
    rpc('turn/start', dict(threadId=t, input=[dict(type='text', text='FUTURE_SETTINGS_PROBE')]))
    done(t, start)
    rpc('thread/resume', dict(threadId=t, model='gpt-6-luna', developerInstructions='LOADED_RESUME_PROBE'))
    f = rpc('thread/fork', dict(threadId=t, developerInstructions='FORK_PROBE', config={'model_reasoning_effort': 'low'}))['result']['thread']['id']
    start = len(transcript)
    rpc('turn/start', dict(threadId=f, input=[dict(type='text', text='FORK_TURN')], effort='low'))
    done(f, start)
    start = len(transcript)
    rpc('review/start', dict(threadId=f, target=dict(type='custom', instructions='Review no changes'), delivery='inline'))
    done(f, start)
    rpc('thread/backgroundTerminals/list', dict(threadId=t))
    rpc('thread/turns/list', dict(threadId=t, limit=10))
    rpc('thread/items/list', dict(threadId=t, turnId=turn, limit=20))
    hold.set()
    received.clear()
    start = len(transcript)
    turn2 = rpc('turn/start', dict(threadId=t, input=[dict(type='text', text='INTERRUPT_PROBE')], effort='low'))['result']['turn']['id']
    assert received.wait(10)
    rpc('turn/interrupt', dict(threadId=t, turnId=turn2))
    done(t, start)
    release.set()
finally:
    release.set()
    p.terminate()
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        p.kill()
        p.wait()
    server.shutdown()
    err.close()
    (O / 'requests.json').write_text(json.dumps(requests, indent=2))
    (O / 'transcript.json').write_text(json.dumps(transcript, indent=2))
    (O / 'rpc-results.json').write_text(json.dumps(rpcs, indent=2))
    print('wire', [(r['body'].get('model'), r['body'].get('reasoning', {}).get('effort')) for r in requests], flush=True)
print(f'work: {WORK}')
