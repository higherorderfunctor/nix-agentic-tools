#!/usr/bin/env python3
"""Offline deterministic review bookkeeping; native adapters own scheduling."""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import html
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent
STAGES = ('lens', 'refine', 'surface', 'dedupe', 'adjudicate', 'finalize')
ROLES = ('evidence', 'defense', 'judge')
SEVERITIES = ('none', 'low', 'medium', 'high', 'critical')
DISPOSITIONS = ('accepted', 'rejected', 'unresolved')
SAFE = re.compile(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,79}$')
HUNK = re.compile(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@')


class ContractError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ContractError(message)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False)


def digest(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def read(path):
    return json.loads(Path(path).read_text())


def atomic(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as out:
        json.dump(value, out, indent=2, sort_keys=True)
        out.write('\n')
        temp = out.name
    os.replace(temp, path)


def journal(run, event, data):
    with (run / 'journal.jsonl').open('a') as stream:
        stream.write(canonical({'at': datetime.now(timezone.utc).isoformat(), 'event': event, 'data': data}) + '\n')


def safe_file(checkout, name, must_exist=False):
    require(isinstance(name, str) and name and '\\' not in name, 'invalid relative source path')
    path = Path(name)
    require(not path.is_absolute() and '..' not in path.parts, 'source path escapes checkout')
    resolved = (checkout / path).resolve()
    require(resolved.is_relative_to(checkout.resolve()), 'source symlink escapes checkout')
    require(not must_exist or resolved.is_file(), 'citation source file is missing')
    return resolved


def git(checkout, *args):
    result = subprocess.run(['git', '-C', str(checkout), *args], capture_output=True, text=True)
    require(result.returncode == 0, 'prepared checkout git verification failed: ' + result.stderr.strip())
    return result.stdout.strip()


def source_pin(checkout, head):
    require(git(checkout, 'rev-parse', 'HEAD') == head, 'checkout HEAD differs from pinned head')
    # Ignored build artifacts are excluded; tracked and untracked source changes refuse.
    require(not git(checkout, 'status', '--porcelain', '--untracked-files=all'), 'checkout has uncommitted source changes')
    return git(checkout, 'rev-parse', 'HEAD^{tree}')


def location(checkout, obj, citation=False):
    require(isinstance(obj, dict), 'location/citation must be an object')
    if citation and 'url' in obj:
        require(isinstance(obj['url'], str) and obj['url'].startswith('https://'), 'external citation needs https URL')
        require(bool(obj.get('version')), 'external citation needs pinned version')
    else:
        safe_file(checkout, obj.get('file'), must_exist=citation and obj.get('side', 'new') != 'old')
        line = obj.get('line')
        require(isinstance(line, int) and not isinstance(line, bool) and line > 0, 'line must be a positive integer')
        end = obj.get('end_line', line)
        require(isinstance(end, int) and not isinstance(end, bool) and end >= line, 'invalid end_line')
        if citation and obj.get('side', 'new') != 'old':
            require(end <= len(safe_file(checkout, obj['file'], True).read_text().splitlines()), 'citation exceeds file')
        require(obj.get('side', 'new') in ('old', 'new'), 'invalid locus side')
    if citation:
        require(isinstance(obj.get('supports'), str) and obj['supports'].strip(), 'citation needs supports')


def candidate(checkout, obj):
    require(isinstance(obj, dict) and isinstance(obj.get('claim'), str) and obj['claim'].strip(), 'candidate needs claim')
    location(checkout, obj.get('locus'))
    for locus in obj.get('related_loci', []):
        location(checkout, locus)
    for cite in obj.get('citations', []):
        location(checkout, cite, True)


def chunks_from_diff(checkout, text, limit, char_limit=12000):
    """Walk hunk counts; bound bodies and retain every changed line exactly once."""
    chunks, changed = [], []
    old_path = new_path = None
    old_no = new_no = old_left = new_left = 0
    body, loci = [], []

    def flush():
        nonlocal body, loci
        if body:
            chunks.append({'id': f'chunk-{len(chunks)+1}', 'file': new_path or old_path,
                           'diff': '\n'.join(body), 'changed_loci': loci})
        body, loci = [], []

    for line in text.splitlines():
        if line.startswith('diff --git '):
            flush()
            old_path = new_path = None
            old_left = new_left = 0
        elif not (old_left or new_left) and line.startswith('--- '):
            flush()
            old_path = None if line[4:] == '/dev/null' else line[6:]
            if old_path:
                safe_file(checkout, old_path)
        elif not (old_left or new_left) and line.startswith('+++ '):
            new_path = None if line[4:] == '/dev/null' else line[6:]
            if new_path:
                safe_file(checkout, new_path)
        elif HUNK.match(line):
            require(not (old_left or new_left), 'truncated diff hunk')
            flush()
            match = HUNK.match(line)
            old_no, old_left, new_no, new_left = (int(match[1]), int(match[2] or 1), int(match[3]), int(match[4] or 1))
            require(bool(old_path or new_path), 'hunk has no file headers')
        elif old_left or new_left:
            tag = line[:1]
            if tag == '\\':
                continue
            require(tag in (' ', '+', '-'), 'malformed hunk body')
            if tag != '+':
                require(old_left > 0, 'hunk old count exceeded')
            if tag != '-':
                require(new_left > 0, 'hunk new count exceeded')
            body.append(line)
            if tag in ('+', '-'):
                locus = {'file': new_path if tag == '+' else old_path, 'side': 'new' if tag == '+' else 'old',
                         'line': new_no if tag == '+' else old_no}
                require(bool(locus['file']), 'changed line lacks side path')
                loci.append(locus)
                changed.append(locus)
            if tag != '+':
                old_no, old_left = old_no + 1, old_left - 1
            if tag != '-':
                new_no, new_left = new_no + 1, new_left - 1
            if len(body) >= limit:
                flush()
    require(not (old_left or new_left), 'truncated diff hunk')
    flush()
        # Mode, rename and binary changes have no text hunk but still owe coverage.
    records = re.split(r'(?=^diff --git )', text, flags=re.MULTILINE)
    for record in records:
        if not record.strip():
            continue
        lines = record.splitlines()
        header = re.match(r'diff --git a/(.+) b/(.+)$', lines[0])
        require(header is not None, 'metadata diff needs file paths')
        for name in header.groups():
            safe_file(checkout, name)
        if any(HUNK.match(line) for line in lines):
            prefix = []
            for line in lines[1:]:
                if HUNK.match(line):
                    break
                if not line.startswith(('--- ', '+++ ', 'index ')):
                    prefix.append(line)
            if prefix:
                chunk = next((c for c in chunks if c['file'] in header.groups()), None)
                require(chunk is not None, 'text diff metadata lacks chunk')
                chunk['diff'] = '\n'.join(prefix) + '\n' + chunk['diff']
                chunk['metadata_change'] = True
            continue
        chunks.append({'id': f'chunk-{len(chunks)+1}', 'file': header[2], 'diff': record,
                       'changed_loci': [], 'metadata_change': True})
    for chunk in chunks:
        if len(chunk['diff']) > char_limit:
            chunk['context_issue'] = {'reason': 'chunk exceeds context character budget',
                                      'characters': len(chunk['diff']), 'digest': digest(chunk['diff'])}
            chunk['diff'] = chunk['diff'][:char_limit]
    return chunks, changed


def pair_proposals(candidates):
    pairs = []
    for index, a in enumerate(candidates):
        at = set(re.findall(r'[a-z0-9]{2,}', a['claim'].lower()))
        for b in candidates[index + 1:]:
            bt = set(re.findall(r'[a-z0-9]{2,}', b['claim'].lower()))
            score = len(at & bt) / max(1, len(at | bt))
            x, y = a['locus'], b['locus']
            geometry = x['file'] == y['file'] and x.get('side', 'new') == y.get('side', 'new') and abs(x['line'] - y['line']) <= 3
            if geometry or score >= .3:
                pairs.append({'a': a['id'], 'b': b['id'], 'geometry': geometry, 'similarity': round(score, 4)})
    return pairs


def versions():
    return {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted([ROOT / 'review.py', ROOT / 'rubric.md', ROOT / 'schemas.json', *ROOT.glob('prompts/*.md'), *ROOT.glob('references/*.md')])}


def prepare(args):
    run = Path(args.run_dir)
    require(run.is_absolute(), 'run-dir must be absolute')
    require(SAFE.fullmatch(args.arm), 'arm must be a safe experiment slug')
    bundle = read(args.input)
    require(bundle.get('schema_version') == 1, 'unsupported input schema')
    target = bundle.get('target', {})
    require(all(isinstance(target.get(k), str) and target[k] for k in ('id', 'base_sha', 'head_sha')), 'target needs id/base_sha/head_sha')
    checkout, diff = Path(bundle['checkout']), Path(bundle['diff'])
    require(checkout.is_absolute() and diff.is_absolute(), 'prepared paths must be absolute')
    require(not run.resolve().is_relative_to(checkout.resolve()), 'run-dir must be outside pinned checkout')
    tree = source_pin(checkout, target['head_sha'])
    text = diff.read_text()
    require(args.chunk_lines > 0 and args.chunk_chars > 0 and args.max_waves > 0, 'budgets must be positive')
    chunks, changed = chunks_from_diff(checkout, text, args.chunk_lines, args.chunk_chars)
    comments = bundle.get('comments', [])
    if isinstance(comments, str):
        require(Path(comments).is_absolute(), 'comments path must be absolute')
        comments = read(comments)
    require(isinstance(comments, list), 'comments must be a list')
    profile = read(args.profile) if args.profile else {}
    require(isinstance(profile, dict), 'profile must be an object')
    prior = read(bundle['prior_report']) if bundle.get('prior_report') else None
    if prior:
        require(prior.get('arm') == args.arm, 'prior report belongs to a different arm')
        require(prior.get('target', {}).get('id') == target['id'], 'prior report belongs to a different target')
        require(prior.get('provenance', {}).get('profile_digest') == digest(profile), 'prior profile is incompatible')
    snapshot = {'schema_version': 1, 'target': target, 'checkout': str(checkout), 'diff': text,
                'comments': comments, 'house_rules': bundle.get('house_rules', []), 'source_tree': tree}
    require(isinstance(snapshot['house_rules'], list) and all(isinstance(rule, str) for rule in snapshot['house_rules']), 'house_rules must be text list')
    input_digest = digest(snapshot)
    require(args.chunk_lines > 0 and args.max_waves > 0, 'budgets must be positive')
    state = {'schema_version': 1, 'arm': args.arm, 'runtime': args.runtime, 'pass': args.review_pass,
             'profile': profile, 'snapshot': snapshot, 'prior': prior, 'chunks': chunks, 'changed_loci': changed,
             'provenance': {'input_digest': input_digest, 'profile_digest': digest(profile), 'versions': versions()},
             'wave': 1, 'max_waves': args.max_waves, 'tasks': {}, 'stages': {}, 'pending_intake': [],
             'intake_receipts': [], 'discovery_receipts': [], 'active_intake': [], 'outcomes': [], 'budget_exhausted': False,
             'base_chunks': chunks, 'context_issues': [{'chunk_id': c['id'], **c['context_issue']} for c in chunks if 'context_issue' in c],
             'controls': {'chunk_lines': args.chunk_lines, 'chunk_chars': args.chunk_chars, 'max_waves': args.max_waves},
             'prior_digest': digest(prior)}
    if run.exists() and (run / 'state.json').exists():
        existing = read(run / 'state.json')
        require(existing['arm'] == args.arm and existing['provenance'] == state['provenance'] and existing['pass'] == args.review_pass
                and existing['controls'] == state['controls'] and existing['runtime'] == args.runtime
                and existing['prior_digest'] == state['prior_digest'], 'prepare replay conflicts with existing run')
        return {'run_dir': str(run), 'arm': args.arm, 'input_digest': input_digest}
    run.mkdir(parents=True, exist_ok=True)
    atomic(run / 'input.json', snapshot)
    atomic(run / 'state.json', state)
    journal(run, 'prepared', {'arm': args.arm, 'runtime': args.runtime, 'provenance': state['provenance']})
    write_status(run, state)
    return {'run_dir': str(run), 'arm': args.arm, 'input_digest': input_digest}


def claim_key(entry):
    return digest({'claim': ' '.join(entry['claim'].casefold().split()), 'locus': entry['locus']})


def final_claims(state):
    # The effective final outcome remains the ceiling until fresh adjudication.
    # Original judge reasoning is archival substantiation, not promotion authority.
    claims = {o.get('claim_key', claim_key(o)): {**o, 'judgment': {k: v for k, v in o.items() if k in ('disposition', 'severity', 'reason', 'citations', 'verify_path')}} for o in state['outcomes']}
    for task in stage_tasks(state, 'adjudicate'):
        data = task['input']
        if data.get('supersedes'):
            claims = {key: value for key, value in claims.items() if value['id'] != data['supersedes']}
        substantiation = {role: {k: v for k, v in result.items() if k in ('citations', 'verify_path', 'reason', 'disposition', 'severity')}
                          for role, result in task['results'].items()}
        claims[data['claim_key']] = {**data, 'id': task['id'], 'judgment': substantiation['judge'], 'substantiation': substantiation}
    return list(claims.values())


def stage_tasks(state, stage):
    return [task for task in state['tasks'].values() if task['wave'] == state['wave'] and task['stage'] == stage]


def add_task(state, stage, data):
    task_id = f"w{state['wave']}-{stage}-{len(stage_tasks(state, stage))+1}"
    task = {'id': task_id, 'stage': stage, 'wave': state['wave'], 'input': data, 'results': {}, 'complete': False, 'worker': None}
    state['tasks'][task_id] = task
    return task


def init_stage(state, stage):
    if stage in state['stages']:
        return
    index = STAGES.index(stage)
    if index:
        previous = STAGES[index - 1]
        require(previous in state['stages'] and all(t['complete'] for t in stage_tasks(state, previous)), 'previous stage is incomplete')
    base = {'checkout': state['snapshot']['checkout'], 'target': state['snapshot']['target'], 'pass': state['pass'], 'house_rules': state['snapshot']['house_rules']}
    if stage == 'lens':
        for chunk in state['chunks']:
            add_task(state, stage, {**base, 'chunk': chunk, 'intake': [i for i in state['active_intake'] if i.get('chunk_id') == chunk['id']]})
    elif stage == 'refine':
        add_task(state, stage, {**base, 'chunks': [{k: v for k, v in c.items() if k != 'diff'} for c in state['chunks']], 'proposals': [t['results']['lens'] for t in stage_tasks(state, 'lens')], 'intake': state['active_intake']})
    elif stage == 'surface':
        lenses = stage_tasks(state, 'refine')[0]['results']['refine']['lenses']
        for lens in lenses:
            for chunk_id in lens['chunk_ids']:
                chunk = next(c for c in state['chunks'] if c['id'] == chunk_id)
                add_task(state, stage, {**base, 'lens': lens, 'chunk': chunk, 'intake': [i for i in state['active_intake'] if i.get('chunk_id') == chunk_id]})
    elif stage == 'dedupe':
        candidates = []
        for task in stage_tasks(state, 'surface'):
            for entry in task['results']['surface']['candidates']:
                candidates.append({**entry, 'id': f"{task['id']}-c{len(candidates)+1}", 'lens': task['input']['lens']})
        add_task(state, stage, {**base, 'candidates': candidates, 'pairs': pair_proposals(candidates), 'prior': state['prior'], 'earlier_claims': state['outcomes']})
    elif stage == 'adjudicate':
        dedupe = stage_tasks(state, 'dedupe')[0]
        by_id = {entry['id']: entry for entry in dedupe['input']['candidates']}
        for group in dedupe['results']['dedupe']['groups']:
            restatements = [d['id'] for d in dedupe['results']['dedupe'].get('dropped', []) if d['duplicate_of'] in group]
            members = [by_id[key] for key in [*group, *restatements]]
            previous = next((o for o in state['outcomes'] if o.get('claim_key') == claim_key(members[0])), None)
            if previous:
                # Keep earlier same-claim instances in the fresh investigation scope.
                known = {canonical(m) for m in members}
                members += [m for m in previous.get('members', []) if canonical(m) not in known]
            add_task(state, stage, {**base, 'claim': members[0]['claim'], 'locus': members[0]['locus'],
                                   'members': members, 'comments': state['snapshot']['comments'], 'prior': state['prior'],
                                   'claim_key': claim_key(members[0]), 'supersedes': next((m['prior_id'] for m in dedupe['results']['dedupe'].get('supersedes', []) if m['candidate_id'] in group), None)})
    else:
        claims = final_claims(state)
        add_task(state, stage, {**base, 'claims': claims, 'coverage': state['changed_loci'], 'context_issues': state['context_issues']})
    state['stages'][stage] = True


def validate_shape(value, schema, where='result'):
    kind = schema.get('type')
    checks = {'object': lambda v: isinstance(v, dict), 'array': lambda v: isinstance(v, list),
              'string': lambda v: isinstance(v, str), 'boolean': lambda v: isinstance(v, bool),
              'integer': lambda v: isinstance(v, int) and not isinstance(v, bool),
              'number': lambda v: isinstance(v, (int, float)) and not isinstance(v, bool)}
    if kind:
        require(checks[kind](value), f'{where} must be {kind}')
    if 'enum' in schema:
        require(value in schema['enum'], f'{where} is outside allowed values')
    if kind == 'object':
        require(set(schema.get('required', [])) <= set(value), f'{where} is missing required fields')
        properties = schema.get('properties', {})
        if schema.get('additionalProperties') is False:
            require(set(value) <= set(properties), f'{where} has unknown fields')
        for key, entry in value.items():
            if key in properties:
                validate_shape(entry, properties[key], where + '.' + key)
    elif kind == 'array':
        require(len(value) >= schema.get('minItems', 0), f'{where} has too few items')
        for index, entry in enumerate(value):
            validate_shape(entry, schema.get('items', {}), f'{where}[{index}]')
    elif kind == 'string':
        require(len(value) >= schema.get('minLength', 0), f'{where} is too short')
    elif kind in ('number', 'integer'):
        require(value >= schema.get('minimum', float('-inf')), f'{where} is too small')


def check_result(state, task, role, result):
    validate_shape(result, read(ROOT / 'schemas.json')['$defs'][role])
    require(isinstance(result, dict) and result.get('task_id') == task['id'], 'result task_id mismatch')
    checkout = Path(state['snapshot']['checkout'])
    for cite in result.get('citations', []):
        location(checkout, cite, True)
    for discovered in result.get('discoveries', []):
        candidate(checkout, discovered)
    if role in ('lens', 'refine'):
        require(isinstance(result.get('lenses'), list) and (result['lenses'] or role == 'refine' and not state['chunks']), 'lenses must be a nonempty list')
        covered = []
        ids = []
        for lens in result['lenses']:
            require(isinstance(lens.get('ecosystem'), str) and lens['ecosystem'].strip(), 'lens needs ecosystem')
            require(isinstance(lens.get('corpus'), str) and lens['corpus'].strip(), 'lens needs corpus')
            require(lens.get('confidence') in ('low', 'medium', 'high'), 'lens needs confidence')
            require(isinstance(lens.get('basis'), list), 'lens needs basis citations')
            for cite in lens['basis']:
                location(checkout, cite, True)
            require(lens['confidence'] == 'low' or lens['basis'], 'confident lens needs cited basis')
            require(set(lens.get('banks', [])) >= {'correctness-security', 'docs', 'maintainability-reuse', 'testing', 'house'}, 'lens omits a baseline bank')
            require(isinstance(lens.get('name'), str) and lens['name'].strip(), 'lens needs name')
            require(isinstance(lens.get('questions'), list) and lens['questions'] and all(isinstance(q, str) and q.strip() for q in lens['questions']), 'lens needs questions')
            if role == 'refine':
                require(isinstance(lens.get('id'), str) and SAFE.fullmatch(lens['id']), 'lens needs safe id')
                ids.append(lens['id'])
                require(isinstance(lens.get('chunk_ids'), list) and lens['chunk_ids'], 'lens needs chunks')
                covered.extend(lens['chunk_ids'])
        if role == 'refine':
            require(len(ids) == len(set(ids)), 'duplicate lens ids')
            require(set(covered) == {c['id'] for c in state['chunks']}, 'refined coverage differs from chunks')
    elif role == 'surface':
        require(isinstance(result.get('candidates'), list), 'surface needs explicit candidates list')
        for entry in result['candidates']:
            candidate(checkout, entry)
        owed = {i['id'] for i in task['input'].get('intake', []) if 'candidate' in i}
        represented = {c.get('intake_id') for c in result['candidates']}
        require(owed <= represented, 'surface omitted an intake claim')
    elif role == 'dedupe':
        require(isinstance(result.get('groups'), list) and isinstance(result.get('dropped', []), list), 'dedupe needs groups/dropped')
        groups = result['groups']
        require(all(isinstance(group, list) and group for group in groups), 'empty dedupe group')
        used = [key for group in groups for key in group]
        for drop in result.get('dropped', []):
            require(isinstance(drop, dict) and drop.get('reason'), 'drop needs reason')
            used.append(drop.get('id'))
        expected = {c['id'] for c in task['input']['candidates']}
        retained = {key for group in groups for key in group}
        for drop in result.get('dropped', []):
            require(drop.get('duplicate_of') in retained, 'dedupe drops require a retained duplicate; validity belongs to evidence/judge')
        owed_intake = {c['intake_id'] for c in task['input']['candidates'] if c.get('intake_id')}
        retained_intake = {c['intake_id'] for c in task['input']['candidates'] if c['id'] in retained and c.get('intake_id')}
        require(owed_intake <= retained_intake, 'dedupe cannot drop an intake claim before adjudication')
        require(len(used) == len(set(used)) and set(used) == expected, 'dedupe must account for every candidate exactly once')
        for mapping in result.get('supersedes', []):
            require(mapping.get('candidate_id') in expected and mapping.get('prior_id') in {o['id'] for o in state['outcomes']} and mapping.get('reason'), 'invalid supersession')
    elif role == 'evidence':
        require(isinstance(result.get('needs_defense'), bool), 'evidence needs boolean needs_defense')
        require(isinstance(result.get('citations'), list) and isinstance(result.get('verify_path'), str), 'evidence needs citations/verify_path')
    elif role == 'defense':
        require(isinstance(result.get('citations'), list) and result.get('reason'), 'defense needs citations/reason')
    elif role == 'judge':
        require(result.get('disposition') in DISPOSITIONS and result.get('severity') in SEVERITIES and result.get('reason'), 'invalid judgment')
        if result['disposition'] == 'accepted':
            require(result.get('citations') and isinstance(result.get('verify_path'), str) and result['verify_path'].strip(), 'acceptance needs citations and verify_path')
    elif role == 'finalize':
        require(isinstance(result.get('decisions'), list), 'finalize needs decisions')
        expected = {claim['id']: claim for claim in final_claims(state)}
        used = []
        for entry in result['decisions']:
            require(entry.get('id') in expected and entry.get('disposition') in DISPOSITIONS and entry.get('severity') in SEVERITIES and entry.get('reason'), 'invalid final decision')
            judge = expected[entry['id']]['judgment']
            require(entry['disposition'] != 'accepted' or judge['disposition'] == 'accepted', 'finalizer cannot promote without renewed evidence')
            require(SEVERITIES.index(entry['severity']) <= SEVERITIES.index(judge['severity']), 'finalizer cannot increase judged severity without renewed evidence')
            used.append(entry['id'])
        require(len(used) == len(set(used)) and set(used) == set(expected), 'finalize must account for all claims')
        presentation_groups(result.get('presentation_groups', []), list(expected.values()))


def intake(state, run, data, origin="user"):
    require(isinstance(data, dict) and isinstance(data.get('claims', []), list), 'intake needs claims list')
    if 'steering' in data:
        require(isinstance(data['steering'], str), 'steering must be text')
    key = digest(data)
    if key in state['intake_receipts']:
        return False
    additions = []
    for entry in data.get('claims', []):
        candidate(Path(state['snapshot']['checkout']), entry)
        identity = digest(entry)
        if origin == 'discovery' and identity in state['discovery_receipts']:
            journal(run, 'exact_discovery_replay', {'candidate': entry, 'reason': 'identical discovery already entered full intake'})
            continue
        if origin == 'discovery':
            state['discovery_receipts'].append(identity)
        additions.append({'id': f'intake-{key[:12]}-{len(additions)+1}', 'candidate': entry})
    if data.get('steering'):
        additions.append({'id': f'intake-{key[:12]}-steering', 'steering': data['steering']})
    state['pending_intake'].extend(additions)
    state['intake_receipts'].append(key)
    journal(run, 'intake', data)
    return bool(additions)


def next_role(task):
    if task['complete']:
        return None
    if task['stage'] != 'adjudicate':
        return task['stage']
    if 'evidence' not in task['results']:
        return 'evidence'
    if task['results']['evidence']['needs_defense'] and 'defense' not in task['results']:
        return 'defense'
    return 'judge'


def task_role(task, requested=None):
    role = requested or task['stage']
    require(role in (ROLES if task['stage'] == 'adjudicate' else (task['stage'],)), 'role does not match task stage')
    if role in ('defense', 'judge'):
        require('evidence' in task['results'], 'evidence receipt missing')
        wants = task['results']['evidence']['needs_defense']
        require(role != 'defense' or wants, 'defense was not requested')
        require(role != 'judge' or not wants or 'defense' in task['results'], 'requested defense receipt missing')
    return role


def without_narratives(value):
    if isinstance(value, dict):
        return {key: without_narratives(item) for key, item in value.items() if key != 'narrative'}
    if isinstance(value, list):
        return [without_narratives(item) for item in value]
    return value


def payload(state, task, requested=None):
    role = task_role(task, requested)
    require(role in task['results'] or len(task.get('submission_attempts', {}).get(role, [])) < 3,
            'submission budget exhausted; new run cannot reset this task/role')
    source_pin(Path(state['snapshot']['checkout']), state['snapshot']['target']['head_sha'])
    require(versions() == state['provenance']['versions'], 'helper/prompt version changed mid-run')
    data = dict(task['input'])
    if task['stage'] == 'adjudicate':
        data = {k: data[k] for k in ('checkout', 'target', 'pass', 'house_rules', 'claim', 'locus', 'members', 'comments')}
        if role == 'judge':
            data['prosecution'] = {k: v for k, v in task['results']['evidence'].items() if k in ('citations', 'verify_path')}
            if 'defense' in task['results']:
                data['challenge'] = {k: v for k, v in task['results']['defense'].items() if k == 'citations'}
        if role == 'defense':
            # Producers' candidate citations are also excluded from independent challenge.
            data['members'] = [{k: v for k, v in member.items() if k not in ('citations', 'narrative')} for member in data['members']]
    data = without_narratives(data)
    data['task_id'] = task['id']
    prompt = (ROOT / 'prompts' / f'{role}.md').read_text() + '\n' + (ROOT / 'rubric.md').read_text()
    if role == 'finalize':
        prompt += '\n' + (ROOT / 'references' / 'peer-communication.md').read_text()
    prompt += '\nOUTPUT JSON SCHEMA\n' + canonical(read(ROOT / 'schemas.json')['$defs'][role])
    attempts = task.get('submission_attempts', {}).get(role, [])
    if attempts and not attempts[-1]['accepted']:
        prompt += '\nCORRECT YOUR PREVIOUS SUBMISSION: ' + attempts[-1]['error']
    return {'role': role, 'task_id': task['id'], 'proposal_id': f"{task['id']}-{role}-{len(attempts) + 1}", 'prompt': prompt, 'input': data,
            'submission': {'attempts': len(attempts), 'remaining': 3 - len(attempts)}}


def status(state):
    final = stage_tasks(state, 'finalize')
    pending = [t['id'] for t in state['tasks'].values() if not t['complete']]
    complete = bool(final) and all(t['complete'] for t in final) and not pending and not state['pending_intake'] and not state['budget_exhausted'] and not state['context_issues']
    return {'arm': state['arm'], 'wave': state['wave'], 'pass': state['pass'], 'stage': next((s for s in reversed(STAGES) if s in state['stages']), 'not-started'),
            'complete': complete, 'pending_tasks': pending, 'pending_intake': len(state['pending_intake']), 'budget_exhausted': state['budget_exhausted'], 'context_issues': state['context_issues']}


def write_status(run, state):
    atomic(run / 'status.json', status(state))
    for stage in STAGES:
        tasks = stage_tasks(state, stage)
        atomic(run / 'status' / f'{stage}.json', {'drained': stage in state['stages'] and all(t['complete'] for t in tasks),
                                               'pending': [t['id'] for t in tasks if not t['complete']], 'wave': state['wave']})


def submit(state, run, task, requested, result):
    role = task_role(task, requested)
    check_result(state, task, role, result)
    if role in task['results']:
        require(task['results'][role] == result, 'conflicting result replay')
    else:
        task['results'][role] = result
        journal(run, role, result)
        if result.get('discoveries'):
            intake(state, run, {'claims': result['discoveries'], 'request_id': task['id'] + ':' + role}, origin='discovery')
    if task['stage'] != 'adjudicate' or role == 'judge':
        task['complete'] = True
        task['worker'] = None
    if role == 'finalize':
        claims = {c['id']: c for c in final_claims(state)}
        state['outcomes'] = [{**claims[d['id']], **claims[d['id']]['judgment'], **d, 'wave': state['wave'],
                              'substantiation': {**claims[d['id']].get('substantiation', {}), 'finalizer': d}}
                             for d in result['decisions']]
        state['presentation_groups'] = presentation_groups(result.get('presentation_groups', []), state['outcomes'])
        journal(run, 'holistic_set', {'ids': [o['id'] for o in state['outcomes']]})
    wants = task['results'].get('evidence', {}).get('needs_defense', False)
    next_role = None if task['complete'] else ('defense' if wants and 'defense' not in task['results'] else 'judge')
    return {'task_id': task['id'], 'role': role, 'complete': task['complete'], 'needs_defense': wants, 'next_role': next_role}


# Submitted-output opportunities, not turns, tool calls, or infrastructure retries.
MAX_SUBMISSIONS = 3


def submit_attempt(state, run, task, requested, result=None, parse_error=None, proposal_id=None, input_digest=None):
    role = task_role(task, requested)
    attempts = task.setdefault('submission_attempts', {}).setdefault(role, [])
    proposal_id = proposal_id or f"{task['id']}-{role}-{len(attempts) + 1}"
    input_digest = input_digest or digest(result if parse_error is None else {'parse_error': parse_error})
    previous = next((item for item in attempts if item['proposal_id'] == proposal_id), None)
    if previous is not None:
        require(previous['input_digest'] == input_digest, 'proposal replay changed submitted bytes/result')
        return previous['receipt']
    if role in task['results']:
        require(parse_error is None and task['results'][role] == result, 'conflicting result replay')
        return {**submit(state, run, task, role, result), 'accepted': True, 'exhausted': False, 'attempt': len(attempts)}
    if len(attempts) >= MAX_SUBMISSIONS:
        return {'task_id': task['id'], 'role': role, 'accepted': False, 'exhausted': True,
                'attempt': len(attempts), 'error': 'submission budget exhausted', 'complete': False}
    error = parse_error
    control = None
    if error is None:
        try:
            control = submit(state, run, task, role, result)
        except ContractError as rejection:
            error = str(rejection)
    receipt = {'proposal_id': proposal_id, 'input_digest': input_digest, 'attempt': len(attempts) + 1, 'accepted': error is None,
               'error': error, 'result_digest': digest(result) if parse_error is None else None}
    attempts.append(receipt)
    journal(run, 'submission_attempt', {'task_id': task['id'], 'role': role, **receipt})
    response = {**(control or {'task_id': task['id'], 'role': role, 'complete': False}),
                'accepted': error is None, 'exhausted': error is not None and len(attempts) == MAX_SUBMISSIONS,
                'attempt': len(attempts), 'proposal_id': proposal_id, 'error': error}
    receipt['receipt'] = response
    return response


def native_controls(state):
    runtime = state['runtime']
    configured = {}
    for role, setting in state.get('profile', {}).get('roles', {}).items():
        if runtime == 'kimchi' and role == 'coordinator':
            continue
        configured[role] = {'model_id': setting.get('model_id')}
        if setting.get('effort') == 'default':
            configured[role].update({'effort_override': 'omitted', 'inherited_session_effort': 'unknown; inspect before launch'})
        else:
            configured[role]['thinking' if runtime == 'kimchi' else 'effortLevel'] = setting.get('effort')
    return {'requested_profile': state.get('profile', {}), 'wired_native_configuration': configured,
            'configuration_status': 'adapter-wiring; not live runtime observation',
            'provider_effective_settings': 'unknown; gateway/model behavior untested',
            'submission_policy': {'initial': 1, 'corrections': 2, 'infrastructure_retries': 0},
            'overhead': {'helper_claim_observations': state.get('helper_claim_observations') if runtime == 'kiro-cli' else None,
                         'observation_kind': 'shared claim command executions; not model/inference counts',
                         'actual_model_requests': None, 'tokens': None, 'cost': None, 'latency_ms': None,
                         'telemetry_status': 'join native telemetry; not observed by helper'}}


def advance(state):
    require('finalize' in state['stages'] and all(t['complete'] for t in stage_tasks(state, 'finalize')), 'finalize receipt missing')
    if not state['pending_intake']:
        return {'continue': False, 'wave': state['wave']}
    if state['wave'] >= state['max_waves']:
        state['budget_exhausted'] = True
        return {'continue': False, 'wave': state['wave'], 'incomplete': True, 'reason': 'wave budget exhausted'}
    active = state['pending_intake']
    # Discoveries become explicit coverage chunks; steering covers every original chunk.
    original = state['base_chunks']
    chunks = []
    for entry in active:
        if 'candidate' in entry:
            locus = entry['candidate']['locus']
            path = safe_file(Path(state['snapshot']['checkout']), locus['file'])
            text = path.read_text().splitlines() if path.is_file() else []
            line = locus['line']
            chunk = {'id': entry['id'], 'file': locus['file'], 'diff': '\n'.join(text[max(0, line-4):line+3]), 'changed_loci': [locus]}
            if len(chunk['diff']) > state['controls']['chunk_chars']:
                state['context_issues'].append({'chunk_id': chunk['id'], 'reason': 'discovery context exceeds character budget'})
                chunk['diff'] = chunk['diff'][:state['controls']['chunk_chars']]
            chunks.append(chunk)
            entry['chunk_id'] = chunk['id']
        else:
            for chunk in original:
                if not any(c['id'] == chunk['id'] for c in chunks):
                    chunks.append(chunk)
    state['chunks'] = chunks
    # Steering is attached to all new tasks rather than one arbitrary locus.
    steering = [e for e in active if 'steering' in e]
    scoped = [e for e in active if 'candidate' in e]
    scoped.extend({**e, 'chunk_id': c['id']} for e in steering for c in chunks)
    state['active_intake'], state['pending_intake'] = scoped, []
    state['stages'] = {}
    state['wave'] += 1
    return {'continue': True, 'wave': state['wave']}


def presentation_groups(groups, outcomes):
    require(isinstance(groups, list), 'presentation groups must be a list')
    known = {o['id'] for o in outcomes}
    seen = set()
    result = []
    for group in groups:
        require(isinstance(group, dict) and isinstance(group.get('title'), str) and group['title'].strip(), 'presentation group needs title')
        ids = group.get('claim_ids')
        require(isinstance(ids, list) and ids and all(isinstance(i, str) for i in ids), 'presentation group needs claim ids')
        require(set(ids) <= known, 'presentation group names unknown claim')
        require(len(ids) == len(set(ids)) and not seen.intersection(ids), 'duplicate presentation group membership')
        seen.update(ids)
        result.append({'title': group['title'], 'claim_ids': ids})
    result.extend({'title': o['claim'], 'claim_ids': [o['id']]} for o in outcomes if o['id'] not in seen)
    return result


def instances(outcome):
    result = {}
    for member in outcome.get('members') or [outcome]:
        for locus in [member['locus'], *member.get('related_loci', [])]:
            physical = {key: locus[key] for key in ('file', 'line', 'end_line') if key in locus}
            physical['side'] = locus.get('side', 'new')
            key = canonical(physical)
            instance = result.setdefault(key, {'locus': physical, 'candidate_ids': [], 'claims': [], 'citations': []})
            candidate_id = member.get('id', outcome['id'])
            if candidate_id not in instance['candidate_ids']:
                instance['candidate_ids'].append(candidate_id)
            if member['claim'] not in instance['claims']:
                instance['claims'].append(member['claim'])
            for citation in member.get('citations', []):
                if citation not in instance['citations']:
                    instance['citations'].append(citation)
    return list(result.values())


def public_outcome(outcome):
    # Report the finding and public substantiation, not copied coordinator input
    # (comment histories, prior reports, arbitrary role fields or transcripts).
    fields = ('id', 'claim', 'locus', 'claim_key', 'disposition', 'severity', 'reason', 'citations', 'verify_path',
              'wave', 'supersedes', 'judgment', 'substantiation')
    result = {key: without_narratives(outcome[key]) for key in fields if key in outcome}
    result['members'] = [{key: member[key] for key in ('id', 'claim', 'locus', 'related_loci', 'citations', 'intake_id') if key in member}
                         for member in outcome.get('members', [])]
    result['instances'] = instances(result)
    return result


def prose(value):
    # Untrusted model/source strings are text, never Markdown links or HTML tags.
    escaped = html.escape(str(value))
    return re.sub(r'([\\`*_{}\[\]()#+.!|~-])', r'\\\1', escaped).replace('\n', ' ')


def citation_text(citation):
    reference = (f"{citation['file']}:{citation['line']}" if 'file' in citation
                 else f"{citation['url']} (version {citation['version']})")
    return prose(reference + ' — ' + citation['supports'])


def finding_details(outcome):
    lines = ['<details><summary><b>Replay path</b></summary>', '', '**Instances**', '']
    for index, instance in enumerate(outcome['instances'], 1):
        locus = instance['locus']
        line = str(locus['line']) + (f"–{locus['end_line']}" if 'end_line' in locus else '')
        lines.append(f"{index}. {prose(locus['file'])}:{line} ({prose(locus.get('side', 'new'))}) — {prose(' / '.join(instance['claims']))}")
        lines.extend('   Citation: ' + citation_text(c) for c in instance['citations'])
    for role, title in (('evidence', 'Evidence checks'), ('defense', 'Counterevidence'), ('judge', 'Independent judgment'), ('finalizer', 'Holistic finalization')):
        record = outcome.get('substantiation', {}).get(role)
        if not record:
            continue
        lines.extend(['', '**' + title + '**', ''])
        if record.get('disposition'):
            lines.append(prose(record['disposition'] + ' · ' + record['severity']))
        if record.get('reason'):
            lines.append(prose(record['reason']))
        lines.extend('- ' + citation_text(c) for c in record.get('citations', []))
        if record.get('verify_path'):
            # A preformatted block preserves complete checks verbatim as safe text.
            # Prompts require numbered action/expected-result legs; never invent results.
            lines.extend(['', '<pre>' + html.escape(record['verify_path']) + '</pre>'])
    lines.extend(['', '</details>', ''])
    return lines


def report(state, run):
    source_pin(Path(state['snapshot']['checkout']), state['snapshot']['target']['head_sha'])
    require(versions() == state['provenance']['versions'], 'helper/prompt version changed mid-run')
    floor = {1: 1, 2: 2, 3: 3}[state['pass']]
    outcomes = [public_outcome(o) for o in state['outcomes']]
    for o in outcomes:
        if o['disposition'] == 'accepted':
            require(o.get('citations') and isinstance(o.get('verify_path'), str) and o['verify_path'].strip(), 'published acceptance needs citations and replay path')
    groups = presentation_groups(state.get('presentation_groups', []), outcomes)
    accepted = [o for o in outcomes if o['disposition'] == 'accepted' and SEVERITIES.index(o['severity']) >= floor]
    filtered = [o for o in outcomes if o['disposition'] == 'accepted' and o not in accepted]
    result = {'schema_version': 1, 'arm': state['arm'], 'runtime': state['runtime'], 'target': state['snapshot']['target'],
              'pass': state['pass'], 'profile': state['profile'], 'provenance': state['provenance'], 'status': status(state),
              'summary': {'accepted': len(accepted), 'rejected': sum(o['disposition'] == 'rejected' for o in outcomes),
                          'unresolved': sum(o['disposition'] == 'unresolved' for o in outcomes), 'filtered': len(filtered)},
              'accepted': accepted, 'filtered': filtered, 'outcomes': outcomes, 'presentation_groups': groups, 'pending_intake': state['pending_intake'],
              'native_controls': native_controls(state),
              'submission_attempts': {t['id']: t.get('submission_attempts', {}) for t in state['tasks'].values()},
              'role_receipts': {role: sum(role in t['results'] for t in state['tasks'].values()) for role in (*STAGES, *ROLES)},
              'coverage': {'changed_loci': state['changed_loci'], 'chunks': state['base_chunks'], 'context_issues': state['context_issues'], 'missing_receipts': status(state)['pending_tasks']}}
    atomic(run / 'report.json', result)
    lines = ['> 🤖 **AI-generated code review** — automated review agent. Findings are evidence-backed (cite-or-stop); reply to discuss, correct, or dismiss.', '',
             f"# Review report: {prose(result['target']['id'])}", '', f"Arm: {prose(state['arm'])}; pass {state['pass']}; {'complete' if result['status']['complete'] else 'INCOMPLETE'}.", '',
             'Structural validation checks citations and receipts; it does not prove claims are true.', '', '## Accepted findings', '']
    by_id = {o['id']: o for o in outcomes}

    def render_selected(selected):
        selected_ids = {o['id'] for o in selected}
        for group in groups:
            visible = [i for i in group['claim_ids'] if i in selected_ids]
            if not visible:
                continue
            lines.extend(['### ' + prose(group['title']), ''])
            for claim_id in visible:
                outcome = by_id[claim_id]
                disposition = 'filtered by pass policy' if outcome in filtered else outcome['disposition']
                lines.extend([f"**{prose(outcome['severity'])} · {prose(disposition)}** — {prose(outcome['claim'])}", '', prose(outcome['reason']), ''])
                lines.extend(finding_details(outcome))

    render_selected(accepted)
    if not accepted:
        lines.append('None accepted for publication under this pass policy.')
    lines.extend(['', '## Unresolved and incomplete work', ''])
    render_selected([o for o in outcomes if o['disposition'] == 'unresolved'])
    for entry in state['pending_intake']:
        lines.append('- Pending full-loop intake: ' + prose(canonical(entry)))
    for task_id in status(state)['pending_tasks']:
        lines.append(f'- Missing worker receipt: {task_id}')
    for issue in state['context_issues']:
        lines.append('- Incomplete context: ' + prose(canonical(issue)))
    other = [o for o in outcomes if o['disposition'] == 'rejected' or o in filtered]
    if other:
        lines.extend(['', '<details><summary><b>Other dispositions</b></summary>', ''])
        render_selected(other)
        lines.extend(['', '</details>', ''])
    lines.extend(['', '## Accounting', '', canonical(result['summary']), '', f"Pending receipts: {canonical(result['coverage']['missing_receipts'])}", f"Pending intake: {len(state['pending_intake'])}", 'Rejected and filtered dispositions with reasons remain in report.json outcomes/filtered; all stage decisions remain in journal.jsonl.', ''])
    (run / 'report.md').write_text('\n'.join(lines))
    return {'report_json': str(run / 'report.json'), 'report_markdown': str(run / 'report.md'), 'status': result['status']}


def execute(args):
    if args.command == 'prepare':
        return prepare(args)
    run = Path(args.run_dir)
    require(run.is_absolute(), 'run-dir must be absolute')
    with (run / '.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = read(run / 'state.json')
        require(state['arm'] == args.arm, 'run belongs to a different arm')
        if args.command in ('tasks', 'claim'):
            init_stage(state, args.stage)
            tasks = stage_tasks(state, args.stage)
            if args.command == 'tasks':
                result = {'stage': args.stage, 'wave': state['wave'], 'tasks': [t for t in tasks if not t['complete']]}
            else:
                require(SAFE.fullmatch(args.worker), 'worker needs safe id')
                task = next((t for t in tasks if not t['complete'] and t['worker'] == args.worker), None)
                if task is None:
                    task = next((t for t in tasks if not t['complete'] and t['worker'] is None), None)
                if task:
                    task['worker'] = args.worker
                result = {'task': ({'id': task['id'], 'next_role': next_role(task), 'completed_roles': list(task['results'])} if task and args.control_only else task), 'drained': all(t['complete'] for t in tasks)}
                observation = {'stage': args.stage, 'worker': args.worker, 'empty': task is None,
                               'coordinator': state['runtime'] == 'kiro-cli' and args.stage == 'adjudicate'}
                counts = state.setdefault('helper_claim_observations', {'claim_commands': 0, 'coordinator_claim_commands': 0, 'empty_claim_commands': 0})
                counts['claim_commands'] += 1
                counts['coordinator_claim_commands'] += int(observation['coordinator'])
                counts['empty_claim_commands'] += int(observation['empty'])
                journal(run, 'claim_observation', observation)
        elif args.command in ('payload', 'submit', 'release'):
            require(args.task in state['tasks'], 'unknown task')
            task = state['tasks'][args.task]
            if args.command == 'payload':
                result = payload(state, task, args.role)
            elif args.command == 'submit':
                try:
                    proposal_bytes = Path(args.result).read_bytes()
                    proposal = json.loads(proposal_bytes)
                    parse_error = None
                except (json.JSONDecodeError, UnicodeDecodeError) as error:
                    proposal, parse_error = None, 'invalid JSON: ' + str(error)
                result = submit_attempt(state, run, task, args.role, proposal, parse_error, args.proposal_id, hashlib.sha256(proposal_bytes).hexdigest())
            else:
                require(task['worker'] == args.worker, 'lease is held by a different worker')
                task['worker'] = None
                result = {'released': task['id']}
        elif args.command == 'intake':
            result = {'added': intake(state, run, read(args.input))}
        elif args.command == 'next-wave':
            result = advance(state)
        elif args.command == 'status':
            result = status(state)
        else:
            result = report(state, run)
        atomic(run / 'state.json', state)
        write_status(run, state)
        return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for command in ('prepare', 'tasks', 'claim', 'payload', 'submit', 'release', 'intake', 'next-wave', 'status', 'report'):
        item = sub.add_parser(command)
        item.add_argument('--run-dir', required=True)
        item.add_argument('--arm', required=True)
        if command == 'prepare':
            item.add_argument('--input', required=True)
            item.add_argument('--runtime', required=True, choices=('kimchi', 'kiro-cli'))
            item.add_argument('--profile')
            item.add_argument('--pass', dest='review_pass', type=int, choices=(1, 2, 3), default=1)
            item.add_argument('--chunk-lines', type=int, default=100)
            item.add_argument('--chunk-chars', type=int, default=12000)
            item.add_argument('--max-waves', type=int, default=3)
        if command in ('tasks', 'claim'):
            item.add_argument('--stage', choices=STAGES, required=True)
        if command == 'claim':
            item.add_argument('--control-only', action='store_true')
        if command in ('claim', 'release'):
            item.add_argument('--worker', required=True)
        if command in ('payload', 'submit', 'release'):
            item.add_argument('--task', required=True)
        if command in ('payload', 'submit'):
            item.add_argument('--role', choices=(*STAGES, *ROLES))
        if command == 'submit':
            item.add_argument('--result', required=True)
            item.add_argument('--proposal-id', required=True)
        if command == 'intake':
            item.add_argument('--input', required=True)
    try:
        print(canonical(execute(parser.parse_args(argv))))
        return 0
    except (ContractError, OSError, ValueError, KeyError, TypeError, AttributeError) as error:
        print(canonical({'error': str(error)}), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
