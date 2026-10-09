#!/usr/bin/env python3
"""Local artifact boundary for LLM-driven GitLab pull/push. No remote transport."""
import argparse
import contextlib
import datetime
import fcntl
import hashlib
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path


def require(condition, message):
    if not condition:
        raise ValueError(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(',', ':'))


def sha(value):
    return hashlib.sha256(value if isinstance(value, bytes) else value.encode()).hexdigest()


def read(path):
    return json.loads(Path(path).read_text())


def write(path, value):
    path = Path(path)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as stream:
        json.dump(value, stream, ensure_ascii=False, sort_keys=True, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
        temporary = stream.name
    os.replace(temporary, path)


def target_id(target):
    return f"gitlab:{target['host']}:{target['project_id']}!{target['mr_iid']}"


def timestamp(value):
    require(isinstance(value, str), 'observation timestamp must be ISO with timezone')
    parsed = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
    require(parsed.tzinfo is not None and parsed.utcoffset() is not None, 'observation timestamp needs timezone')
    return parsed


def recent(value):
    age = (datetime.datetime.now(datetime.timezone.utc) - timestamp(value)).total_seconds()
    require(-60 <= age <= 300, 'publication observation is stale or future-dated; refresh before writing')


def snapshot(path):
    value = read(path)
    require(value.get('schema_version') == 1 and value.get('complete') is True,
            'snapshot must be version 1 with complete=true')
    target = value.get('target', {})
    require(isinstance(target.get('host'), str) and re.fullmatch(r'[A-Za-z0-9.-]+(?::[0-9]+)?', target['host']),
            'host must be an explicit hostname, without credentials or URL components')
    for key in ('project_id', 'mr_iid'):
        require(isinstance(target.get(key), str) and re.fullmatch(r'[1-9][0-9]*', target[key]),
                f'{key} must be a positive decimal string')
    refs = {key: target.get(key) for key in ('base_sha', 'head_sha', 'start_sha')}
    require(all(isinstance(v, str) and re.fullmatch(r'[0-9a-f]{40}|[0-9a-f]{64}', v) for v in refs.values()),
            'refs must be full lowercase Git object IDs')
    require(value.get('before_refs') == refs == value.get('after_refs'), 'acquisition refs changed')
    timestamp(value.get('observed_at'))
    require(isinstance(value.get('discussions'), list), 'discussions must be a list')
    discussions, notes = set(), set()
    for discussion in value['discussions']:
        require(isinstance(discussion, dict) and isinstance(discussion.get('id'), str) and discussion['id'], 'discussion needs string id')
        require(discussion['id'] not in discussions, 'duplicate discussion id')
        discussions.add(discussion['id'])
        require(isinstance(discussion.get('notes'), list), 'discussion needs notes list')
        for note in discussion['notes']:
            require(isinstance(note, dict) and isinstance(note.get('id'), str) and note['id'], 'note needs string id')
            require(note['id'] not in notes, 'duplicate note id')
            notes.add(note['id'])
            require(isinstance(note.get('body'), str) and isinstance(note.get('updated_at'), str), 'note needs body and updated_at')
    return value


def git(checkout, *arguments):
    return subprocess.check_output(['@git@', '-C', str(checkout), *arguments], text=True, stderr=subprocess.PIPE)


def freeze(args):
    value = snapshot(args.snapshot)
    checkout = Path(args.checkout).resolve(strict=True)
    require(checkout.is_dir(), 'checkout must be a directory')
    output = Path(args.output_dir).absolute()
    require(not output.resolve().is_relative_to(checkout), 'output directory must be outside checkout')
    require(not output.exists(), 'freeze refuses to overwrite')
    target = value['target']
    require(git(checkout, 'rev-parse', 'HEAD').strip() == target['head_sha'], 'checkout HEAD differs')
    require(not git(checkout, 'status', '--porcelain', '--untracked-files=all'), 'checkout must be clean')
    for name in ('base_sha', 'head_sha'):
        require(git(checkout, 'rev-parse', '--verify', target[name] + '^{commit}').strip() == target[name], 'ref is not a local commit')
    diff = git(checkout, 'diff', '--no-ext-diff', '--no-textconv', '--unified=3', target['base_sha'], target['head_sha'], '--')
    rules = read(args.house_rules) if args.house_rules else []
    require(isinstance(rules, list) and all(isinstance(r, str) for r in rules), 'house rules must be text list')
    intake = read(args.intake) if args.intake else {'claims': []}
    require(isinstance(intake, dict) and isinstance(intake.get('claims'), list), 'intake must contain claims list')
    comments = []
    for discussion in value['discussions']:
        comments.append({**{key: discussion[key] for key in ('id', 'resolved', 'resolvable') if key in discussion},
                         'notes': [{key: note[key] for key in ('id', 'body', 'updated_at', 'created_at', 'position', 'system') if key in note}
                                   for note in discussion['notes']]})
    # A second local check detects ordinary source drift while deriving the diff.
    require(git(checkout, 'rev-parse', 'HEAD').strip() == target['head_sha'] and not git(checkout, 'status', '--porcelain', '--untracked-files=all'), 'checkout changed during freeze')
    output.mkdir(parents=True)
    (output / 'review.diff').write_text(diff)
    write(output / 'snapshot.json', value)
    write(output / 'intake.json', intake)
    write(output / 'bundle.json', {'schema_version': 1, 'target': {'id': target_id(target), 'base_sha': target['base_sha'], 'head_sha': target['head_sha']},
                                 'checkout': str(checkout), 'diff': str(output / 'review.diff'), 'comments': comments, 'house_rules': rules})
    sidecar = {'schema_version': 1, 'target': target, 'snapshot_digest': sha(canonical(value)), 'diff_sha256': sha(diff),
               'bundle_sha256': sha((output / 'bundle.json').read_bytes()), 'intake_sha256': sha((output / 'intake.json').read_bytes()),
               'note_hashes': {note['id']: sha(note['body']) for d in value['discussions'] for note in d['notes']}}
    write(output / 'transport.json', sidecar)
    receipt = {'state': 'frozen', 'ready': True, 'bundle': str(output / 'bundle.json'), 'snapshot': str(output / 'snapshot.json'),
               'intake': str(output / 'intake.json'), 'transport': str(output / 'transport.json'), 'hashes': sidecar}
    write(output / 'freeze-receipt.json', receipt)
    return receipt


def verify_freeze(args):
    output = Path(args.frozen_dir).resolve(strict=True)
    sidecar = read(output / 'transport.json')
    bundle = read(output / 'bundle.json')
    require(sha((output / 'bundle.json').read_bytes()) == sidecar['bundle_sha256'], 'frozen bundle changed')
    require(sha((output / 'review.diff').read_bytes()) == sidecar['diff_sha256'], 'frozen diff changed')
    require(sha(canonical(snapshot(output / 'snapshot.json'))) == sidecar['snapshot_digest'], 'frozen snapshot changed')
    require(sha((output / 'intake.json').read_bytes()) == sidecar['intake_sha256'], 'frozen intake changed')
    require(git(bundle['checkout'], 'rev-parse', 'HEAD').strip() == sidecar['target']['head_sha'] and not git(bundle['checkout'], 'status', '--porcelain', '--untracked-files=all'), 'frozen checkout changed')
    return {'state': 'frozen', 'ready': True, 'bundle': str(output / 'bundle.json'), 'snapshot': str(output / 'snapshot.json'),
            'intake': str(output / 'intake.json'), 'transport': str(output / 'transport.json'), 'hashes': sidecar}


def find_note(value, discussion_id, note_id):
    for discussion in value['discussions']:
        if discussion['id'] == discussion_id:
            for note in discussion['notes']:
                if note['id'] == note_id:
                    return note
    raise ValueError('selected note is absent from selected discussion')


def plan(args):
    value = snapshot(args.snapshot)
    report_bytes = Path(args.report_json).read_bytes()
    markdown_bytes = Path(args.report_md).read_bytes()
    report = json.loads(report_bytes)
    text = markdown_bytes.decode('utf-8')
    target = value['target']
    require(report.get('schema_version') == 1 and report.get('status', {}).get('complete') is True, 'selected report must be complete version 1')
    require(report.get('target') == {'id': target_id(target), 'base_sha': target['base_sha'], 'head_sha': target['head_sha']}, 'report target differs from snapshot')
    require(isinstance(report.get('provenance', {}).get('input_digest'), str), 'report needs input provenance')
    require(text.strip(), 'report Markdown is empty')
    if args.action != 'create':
        require(args.discussion_id and any(d['id'] == args.discussion_id for d in value['discussions']), 'selected discussion is absent')
    if args.action == 'update':
        note = find_note(value, args.discussion_id, args.note_id)
        require(args.baseline_hash == sha(note['body']), 'update baseline hash differs')
        require(args.owner_id and (note.get('author') or {}).get('id') == args.owner_id, 'update requires own note author identity')
        require(re.search(r'<!-- review-ab:report=[0-9a-f]{64} -->', note['body']), 'update requires existing report ownership marker')
    else:
        require(not args.note_id and not args.baseline_hash and not args.owner_id, 'note id/baseline hash/owner id only apply to update')
    identity = {'target': target, 'report_json_sha256': sha(report_bytes), 'report_md_sha256': sha(markdown_bytes),
                'input_digest': report['provenance']['input_digest'], 'action': args.action, 'discussion_id': args.discussion_id, 'note_id': args.note_id, 'baseline_hash': args.baseline_hash, 'owner_id': args.owner_id}
    operation = sha(canonical(identity))
    marker = f'<!-- review-ab:report={operation} -->'
    body = text + ('\n' if not text.endswith('\n') else '') + '\n' + marker + '\n'
    endpoint = f"projects/{target['project_id']}/merge_requests/{target['mr_iid']}/discussions"
    if args.action != 'create':
        # GitLab discussion/note ids are supplied remote identities, not URL fragments.
        from urllib.parse import quote
        endpoint += '/' + quote(args.discussion_id, safe='') + '/notes'
        if args.action == 'update':
            endpoint += '/' + quote(args.note_id, safe='')
    output = Path(args.publication_dir).absolute()
    require(not output.exists(), 'plan refuses to overwrite; revisions need new publication directory')
    output.mkdir(parents=True)
    sealed = {**identity, 'schema_version': 1, 'operation_id': operation, 'marker': marker, 'body': body,
              'body_sha256': sha(body), 'snapshot_digest': sha(canonical(value)), 'method': 'PUT' if args.action == 'update' else 'POST', 'endpoint': endpoint}
    write(output / 'plan.json', sealed)
    write(output / 'request.json', {'body': body})
    write(output / 'ledger.json', {'state': 'planned', 'plan_digest': sha(canonical(sealed)), 'preflight': None, 'receipt': None, 'ever_started': False})
    return {'publication_dir': str(output), 'operation_id': operation, 'plan': str(output / 'plan.json')}


@contextlib.contextmanager
def locked(directory):
    root = Path(directory).resolve(strict=True)
    with (root / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        plan = read(root / 'plan.json')
        ledger = read(root / 'ledger.json')
        require(sha(canonical(plan)) == ledger['plan_digest'], 'sealed plan changed')
        require(read(root / 'request.json') == {'body': plan['body']}, 'sealed request changed')
        yield root, plan, ledger


def event(root, kind, data):
    with (root / 'journal.jsonl').open('a') as stream:
        stream.write(canonical({'at': datetime.datetime.now(datetime.timezone.utc).isoformat(), 'event': kind, 'data': data}) + '\n')
        stream.flush()
        os.fsync(stream.fileno())


def observe(args):
    with locked(args.publication_dir) as (root, plan, ledger):
        # A refused fresh observation must never leave an old ready/verified control.
        ledger.update(state='blocked', preflight=None)
        write(root / 'ledger.json', ledger)
        value = snapshot(args.snapshot)
        recent(value['observed_at'])
        require(value['target'] == plan['target'], 'publication target/refs changed')
        matches = [(d, n) for d in value['discussions'] for n in d['notes'] if plan['marker'] in n['body']]
        require(len(matches) <= 1, 'duplicate operation marker: reconciliation required')
        if matches:
            discussion, note = matches[0]
            require(note['body'] == plan['body'], 'operation marker has conflicting body')
            require(plan['action'] == 'create' or discussion['id'] == plan['discussion_id'], 'operation marker appeared in wrong discussion')
            require(plan['action'] != 'update' or note['id'] == plan['note_id'], 'operation marker appeared on wrong note')
            receipt = {'operation_id': plan['operation_id'], 'discussion_id': discussion['id'], 'note_id': note['id'],
                       'body_sha256': sha(note['body']), 'observed_at': value['observed_at'], 'snapshot_digest': sha(canonical(value))}
            if ledger['receipt']:
                require(all(ledger['receipt'][key] == receipt[key] for key in ('discussion_id', 'note_id', 'body_sha256')), 'receipt identity conflict')
            ledger.update(state='verified', receipt=receipt, preflight=None)
        elif ledger['ever_started'] or ledger['receipt']:
            ledger.update(state='uncertain', preflight=None)
        else:
            if plan['action'] != 'create':
                require(any(d['id'] == plan['discussion_id'] for d in value['discussions']), 'selected discussion disappeared')
            if plan['action'] == 'update':
                note = find_note(value, plan['discussion_id'], plan['note_id'])
                require(sha(note['body']) == plan['baseline_hash'], 'update note changed; preserve author edits and replan')
                require((note.get('author') or {}).get('id') == plan['owner_id'], 'update note author differs')
            ledger['preflight'] = {'snapshot_digest': sha(canonical(value)), 'observed_at': value['observed_at']}
            ledger['state'] = 'ready'
        write(root / 'ledger.json', ledger)
        event(root, 'observation', {'state': ledger['state'], 'snapshot_digest': sha(canonical(value))})
        return ledger


def begin(args):
    with locked(args.publication_dir) as (root, plan, ledger):
        require(ledger['state'] == 'ready' and ledger['preflight'], 'fresh observation required; started/uncertain/verified actions cannot retry')
        recent(ledger['preflight']['observed_at'])
        ledger['state'] = 'started'
        ledger['ever_started'] = True
        write(root / 'ledger.json', ledger)
        event(root, 'intent', {'operation_id': plan['operation_id'], 'preflight': ledger['preflight']})
        return {'state': 'started', 'operation_id': plan['operation_id'], 'host': plan['target']['host'], 'method': plan['method'],
                'endpoint': plan['endpoint'], 'request': str(root / 'request.json')}


def status(args):
    with locked(args.publication_dir) as (_, plan, ledger):
        return {'operation_id': plan['operation_id'], 'target': plan['target'], 'action': plan['action'],
                'report_json_sha256': plan['report_json_sha256'], 'report_md_sha256': plan['report_md_sha256'],
                'input_digest': plan['input_digest'], 'body_sha256': plan['body_sha256'], **ledger}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    frozen = commands.add_parser('freeze')
    for flag in ('snapshot', 'checkout', 'output-dir'):
        frozen.add_argument('--' + flag, required=True)
    for flag in ('house-rules', 'intake'):
        frozen.add_argument('--' + flag)
    verification = commands.add_parser('verify-freeze')
    verification.add_argument('--frozen-dir', required=True)
    planned = commands.add_parser('plan')
    for flag in ('snapshot', 'report-json', 'report-md', 'publication-dir'):
        planned.add_argument('--' + flag, required=True)
    planned.add_argument('--action', choices=('create', 'reply', 'update'), required=True)
    for flag in ('discussion-id', 'note-id', 'baseline-hash', 'owner-id'):
        planned.add_argument('--' + flag)
    for name in ('begin', 'observe', 'status'):
        command = commands.add_parser(name)
        command.add_argument('--publication-dir', required=True)
        if name == 'observe':
            command.add_argument('--snapshot', required=True)
    args = parser.parse_args()
    try:
        print(canonical(globals()[args.command.replace('-', '_')](args)))
    except (KeyError, OSError, TypeError, ValueError, subprocess.CalledProcessError) as error:
        print(canonical({'state': 'refused', 'reason': str(error)}))
        return 2
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
