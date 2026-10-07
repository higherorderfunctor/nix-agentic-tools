#!/usr/bin/env python3
"""Run pinned Kimchi against a scripted local gateway, using only a fake key."""
import argparse
import http.server
import json
import os
from pathlib import Path
import subprocess
import threading
import queue

import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'common'))
import pin  # noqa: E402

# Cases: native (codex:O), rpc (codex:R), rpc-child (codex:C), native-permissions (codex:Q),
# native-resume / native-resume-blocked (codex:B). Writes <work>/offline-<case>/;
# work = $PROBE_OUT/kimchi-codex or a fresh temp dir.
ROOT = pin.workdir('kimchi-codex')
BINARY = str(pin.package('kimchi') / 'bin' / 'kimchi')


def run(case):
    folder = ROOT / ('offline-' + case)
    folder.mkdir(exist_ok=True)
    home = folder / 'home'
    work = folder / 'cwd'
    home.mkdir(exist_ok=True)
    work.mkdir(exist_ok=True)
    harness = home / '.config/kimchi/harness'
    harness.mkdir(parents=True, exist_ok=True)
    (harness / 'settings.json').write_text(json.dumps({'defaultProvider': 'kimchi-dev', 'defaultModel': 'parent-fixture', 'defaultThinkingLevel': 'low', 'defaultProjectTrust': 'never', 'resources': {'extensions.memory': False}}))
    marker = work / 'child-marker.txt'
    parent_marker = work / 'parent-marker.txt'
    if case == 'native-permissions':
        marker.unlink(missing_ok=True)
        parent_marker.unlink(missing_ok=True)
        (harness / 'permissions.json').write_text(json.dumps({'defaultMode': 'default', 'deny': ['Write', 'write', 'Bash', 'bash']}))
    elif case == 'native-resume':
        (harness / 'permissions.json').write_text(json.dumps({'defaultMode': 'default', 'allow': ['resume_subagent']}))
    requests = []
    parent_calls = 0
    child_calls = 0
    stream_started = threading.Event()
    release_stream = threading.Event()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            requests.append({'method': 'GET', 'path': self.path})
            models = [dict(slug=m, display_name=m, provider='ai-enabler', reasoning=True, input_modalities=['text'], limits={'context_window': 100000, 'max_output_tokens': 8192}, is_serverless=True) for m in ['parent-fixture', 'child-fixture']]
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({'models': models} if 'metadata' in self.path else {}).encode())

        def do_POST(self):
            nonlocal parent_calls, child_calls
            body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))) or '{}')
            requests.append({'method': 'POST', 'path': self.path, 'body': body})
            if 'chat/completions' not in self.path:
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{}')
                return
            model = body.get('model')
            if model == 'parent-fixture':
                parent_calls += 1
            if model == 'child-fixture':
                child_calls += 1
            call = case != 'rpc' and model == 'parent-fixture' and parent_calls == 1
            child_write = case == 'native-permissions' and model == 'child-fixture' and child_calls == 1
            parent_write = case == 'native-permissions' and model == 'parent-fixture' and parent_calls == 2
            if call:
                args = {'prompt': 'Return CHILD_OK.', 'description': 'Offline native child probe', 'subagent_type': 'General-purpose', 'model': 'child-fixture', 'thinking': 'high', 'run_in_background': False, 'max_duration': 15}
                delta = {'role': 'assistant', 'tool_calls': [{'index': 0, 'id': 'fixture-agent', 'type': 'function', 'function': {'name': 'Agent', 'arguments': json.dumps(args)}}]}
            elif case in ['native-resume', 'native-resume-blocked'] and model == 'parent-fixture' and parent_calls == 2:
                tool_message = next(m for m in body['messages'] if m.get('role') == 'tool' and m.get('tool_call_id') == 'fixture-agent')
                outcome = json.loads(tool_message['content'].split('agent_outcome:\n', 1)[1])
                args = {'agent_id': outcome['agent_id'], 'prompt': 'Continue the completed fixture with FOLLOWUP_OK.', 'max_turns': 2, 'max_duration': 15}
                delta = {'role': 'assistant', 'tool_calls': [{'index': 0, 'id': 'fixture-resume', 'type': 'function', 'function': {'name': 'resume_subagent', 'arguments': json.dumps(args)}}]}
            elif child_write or parent_write:
                delta = {'role': 'assistant', 'tool_calls': [{'index': 0, 'id': 'fixture-write', 'type': 'function', 'function': {'name': 'write', 'arguments': json.dumps({'path': str(marker if child_write else parent_marker), 'content': 'OFFLINE_CHILD_WRITE'})}}]}
            else:
                delta = {'role': 'assistant', 'content': 'CHILD_OK' if model == 'child-fixture' else 'PARENT_OK'}
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.end_headers()
            if (case == 'rpc' and parent_calls == 1) or (case == 'rpc-child' and model == 'child-fixture'):
                stream_started.set()
                release_stream.wait(15)
            try:
                for fragment, reason in [(delta, None), ({}, 'tool_calls' if 'tool_calls' in delta else 'stop')]:
                    event = {'id': 'fixture', 'object': 'chat.completion.chunk', 'model': model, 'choices': [{'index': 0, 'delta': fragment, 'finish_reason': reason}]}
                    self.wfile.write(('data: ' + json.dumps(event) + '\n\n').encode())
                    self.wfile.flush()
                self.wfile.write(b'data: [DONE]\n\n')
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                requests.append({'event': 'stream_disconnected', 'model': model})

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = 'http://127.0.0.1:' + str(server.server_port)
    env = {'HOME': str(home), 'PATH': os.environ['PATH'], 'XDG_CONFIG_HOME': str(home / '.config'), 'KIMCHI_API_KEY': 'offline-fake-key', 'KIMCHI_BASE_URL': url, 'KIMCHI_REMOTE_ENDPOINT': url, 'KIMCHI_WEB_APP_URL': url, 'OLLAMA_HOST': url, 'KIMCHI_TELEMETRY_ENABLED': '0', 'KIMCHI_SKIP_UPDATE_CHECK': '1', 'CI': '1', 'TERM': 'dumb'}
    command = [BINARY, '--mode', 'json', '-p', '--provider', 'kimchi-dev', '--model', 'parent-fixture', '--thinking', 'low', '--no-session', 'Delegate the offline fixture task.']
    try:
        if case.startswith('rpc'):
            command = command[:1] + ['--mode', 'rpc', '--provider', 'kimchi-dev', '--model', 'parent-fixture', '--thinking', 'low', '--no-session']
            with (folder / 'stderr.txt').open('w') as err:
                proc = subprocess.Popen(command, cwd=work, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=err, text=True, bufsize=1)
                events = []
                arrivals = queue.Queue()
                def read_output():
                    for line in proc.stdout:
                        events.append(line)
                        try:
                            arrivals.put(json.loads(line))
                        except json.JSONDecodeError:
                            pass
                reader = threading.Thread(target=read_output, daemon=True)
                reader.start()
                sent = []
                status = {'command': command, 'sent': sent}
                def send(kind, **fields):
                    cmd = dict(type=kind, id=str(len(sent)), **fields)
                    sent.append(cmd)
                    proc.stdin.write(json.dumps(cmd) + '\n')
                    proc.stdin.flush()
                    if kind == 'prompt':
                        return
                    while True:
                        event = arrivals.get(timeout=15)
                        if event.get('type') == 'response' and event.get('id') == cmd['id']:
                            return event
                try:
                    responses = [send('get_state'), send('get_available_models')]
                    send('prompt', message='RPC first turn')
                    assert stream_started.wait(15), 'RPC stream did not start'
                    if case == 'rpc-child':
                        responses.extend([send('get_state'), send('abort')])
                        release_stream.set()
                    else:
                        responses.extend([send('get_state'), send('steer', message='RPC steering message'), send('set_model', provider='kimchi-dev', modelId='child-fixture'), send('set_thinking_level', level='high'), send('get_state')])
                        release_stream.set()
                        # A prompt response acknowledges preflight, not completion.
                        while True:
                            event = arrivals.get(timeout=15)
                            if event.get('type') == 'agent_settled':
                                break
                    responses.extend([send('get_messages'), send('get_last_assistant_text'), send('abort'), send('get_state')])
                    status = {'command': command, 'sent': sent, 'responses': responses}
                finally:
                    release_stream.set()
                    proc.stdin.close()
                    try:
                        proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        proc.terminate()
                        proc.wait(timeout=5)
                    reader.join(timeout=2)
                    (folder / 'stdout.jsonl').write_text(''.join(events))
                    status['returncode'] = proc.returncode
        else:
            result = subprocess.run(command, cwd=work, env=env, capture_output=True, text=True, timeout=55)
            (folder / 'stdout.jsonl').write_text(result.stdout)
            (folder / 'stderr.txt').write_text(result.stderr)
            status = {'returncode': result.returncode, 'command': command}
    except subprocess.TimeoutExpired as error:
        (folder / 'stdout.jsonl').write_bytes(error.stdout or b'')
        (folder / 'stderr.txt').write_bytes(error.stderr or b'')
        status = {'timeout': True, 'command': command}
    finally:
        server.shutdown()
    (folder / 'requests.json').write_text(json.dumps(requests, indent=2) + '\n')
    model_requests = [r['body'] for r in requests if r.get('method') == 'POST' and 'chat/completions' in r['path']]
    status['calls'] = [{'model': r.get('model'), 'reasoning_effort': r.get('reasoning_effort'), 'tools': [t['function']['name'] for t in r.get('tools', [])]} for r in model_requests]
    status['childObserved'] = any(r.get('model') == 'child-fixture' and r.get('reasoning_effort') == 'high' for r in model_requests)
    if case == 'native-permissions':
        status['childWriteDespiteParentDeny'] = marker.exists() and marker.read_text() == 'OFFLINE_CHILD_WRITE'
        status['parentWriteDenied'] = not parent_marker.exists()
        assert status['childWriteDespiteParentDeny'] and status['parentWriteDenied'], status
    if case == 'rpc':
        assert any(r.get('command') == 'get_state' and r.get('data', {}).get('isStreaming') and r.get('data', {}).get('model', {}).get('id') == 'child-fixture' and r.get('data', {}).get('thinkingLevel') == 'high' for r in status['responses']), status
        assert status['childObserved'], status
    else:
        assert status['childObserved'], status
    if case == 'rpc-child':
        assert any(r.get('command') == 'get_messages' and any(m.get('role') == 'toolResult' and m.get('details', {}).get('status') == 'stopped' for m in r.get('data', {}).get('messages', [])) for r in status['responses']), status
    if case in ['native-resume', 'native-resume-blocked']:
        rollout = [json.loads(line) for line in (folder / 'stdout.jsonl').read_text().splitlines() if line.startswith('{')]
        results = [e for e in rollout if e.get('type') == 'tool_execution_end' and e.get('toolName') == 'resume_subagent']
        if case == 'native-resume':
            status['completedSessionResumed'] = bool(results and results[-1].get('result', {}).get('details', {}).get('agentOutcome', {}).get('resume_attempts') == 1)
            assert status['completedSessionResumed'], status
        else:
            status['noUiResumeDenied'] = bool(results and results[-1].get('isError') and 'no UI to confirm' in json.dumps(results[-1]))
            assert status['noUiResumeDenied'], status
    (folder / 'result.json').write_text(json.dumps(status, indent=2) + '\n')
    print(json.dumps(status, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('case', choices=['native', 'native-permissions', 'native-resume', 'native-resume-blocked', 'isolated', 'rpc', 'rpc-child'])
    run(parser.parse_args().case)
