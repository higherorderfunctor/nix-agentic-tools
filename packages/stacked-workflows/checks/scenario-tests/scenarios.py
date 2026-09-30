#!/usr/bin/env python3
"""Persistent behavioral scenarios. Exit codes never substitute for assertions."""
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time

from blocks import load, sources, PREFIX

ROOT = Path(__file__).resolve().parent
STRICT = '#!/usr/bin/env bash\nset -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\n'


class Case:
    def __init__(self, spec, run, docs, blocks, env):
        self.spec, self.docs, self.blocks = spec, docs, blocks
        self.sources = sources(Path(env['SCENARIO_SOURCE']), env.get('SCENARIO_REVISION') or None)
        self.root = run / spec['id']
        self.root.mkdir()
        self.env = dict({key: value for key, value in env.items() if not key.startswith('GIT_')}, CASE_ROOT=str(self.root), TOPOLOGY=spec['topology'], SCENARIO_RUN=str(run))
        self.env.update(spec.get('env', {}))
        self.env.update(HOME=str(self.root / 'home'), XDG_CONFIG_HOME=str(self.root / 'home/.config'), TMPDIR=str(self.root / 'tmp'), GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='t', GIT_AUTHOR_EMAIL='t@t', GIT_COMMITTER_NAME='t', GIT_COMMITTER_EMAIL='t@t', GIT_EDITOR='true', GIT_AUTHOR_DATE='2000-01-01T00:00:00+00:00', GIT_COMMITTER_DATE='2000-01-01T00:00:00+00:00', NO_COLOR='1')
        for key in ('GIT_CONFIG_GLOBAL', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'BASH_ENV', 'ENV'):
            self.env.pop(key, None)
        self.log = (self.root / 'case.log').open('w')
        self.used, self.checks, self.step = [], [], 0
        self.planned = spec['block_ids']
        self.roles = spec['block_roles']
        if len(self.planned) != len(self.roles):
            raise ValueError('Block IDs and roles must have equal length')
        self.block_cursor = 0
        self.shell_steps = []
        for block_id in self.planned:
            if block_id not in blocks:
                raise RuntimeError('Unknown manifest block ID: ' + block_id)
        self.cmd(['bash', str(ROOT / 'topologies.sh')], ROOT, require=True)
        self.wt = self.root / 'wt-a'
        self.before = self.snapshot()

    def cmd(self, argv, cwd=None, require=False):
        result = subprocess.run(argv, cwd=cwd or self.wt, env=self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=65)
        self.log.write('$ ' + shlex.join(map(str, argv)) + '\n' + result.stdout + result.stderr + f'\n[exit {result.returncode}]\n')
        self.log.flush()
        if hasattr(self, 'before') and argv[0] == 'git':
            verb = argv[1] if len(argv) > 1 else ''
            mutate = verb in ('absorb', 'add', 'amend', 'checkout', 'commit', 'hide', 'move', 'rebase', 'reset', 'restack', 'restore', 'revise', 'submit') or verb == 'test' and len(argv) > 2 and argv[2] == 'fix'
            event = 'mutator' if mutate else 'query-error' if verb == 'query' and result.returncode else 'empty-selection' if verb == 'query' and not result.stdout.strip() else None
            if event:
                with (self.root / 'command-trace.tsv').open('a') as trace:
                    trace.write(f'{self.step}\t{event}\t{result.returncode}\t{shlex.join(argv)}\n')
        if require and result.returncode:
            raise RuntimeError(f'Command failed: {argv}: {result.stderr[-1000:]}')
        return result

    def git(self, *args, cwd=None):
        return self.cmd(['git', *args], cwd).stdout.strip()

    def body(self, skill, marker):
        path = PREFIX + (f'skills/{skill}/SKILL.md' if not skill.endswith('.md') else 'references/' + skill)
        if self.block_cursor >= len(self.planned):
            raise RuntimeError(f'Manifest exhausted while requesting {skill}:{marker!r}')
        block_id = self.planned[self.block_cursor]
        block = self.blocks[block_id]
        if block['path'] != path or marker not in block['body']:
            raise RuntimeError(f'{block_id} no longer contains {marker!r}, the command this scenario runs '
                               f'(step {self.block_cursor}); if the change is intended, update this case\'s block_ids and markers')
        self.block_cursor += 1
        self.used.append(block_id)
        return block['body']

    def shell(self, body, suffix='', replacements=None):
        for old, new in (replacements or {}).items():
            body = body.replace(old, new)
        self.step += 1
        path = self.root / f'block-{self.step:02}.sh'
        path.write_text(body + '\n' + suffix + '\n')
        previous = self.shell_steps[-1]['block_end'] if self.shell_steps else 0
        indices = list(range(previous, self.block_cursor))
        step_roles = [self.roles[index] for index in indices]
        wrapper = self.root / 'trace-env.sh'
        wrapper.write_text((ROOT / 'trace-env.sh').read_text())
        self.env['BASH_ENV'] = str(wrapper)
        self.env['SCENARIO_TRACE'] = str(self.root / 'command-trace.tsv')
        self.env['SCENARIO_STEP'] = str(self.step)
        self.env['SCENARIO_SELECTION'] = '1' if 'selection' in step_roles else '0'
        result = self.cmd(['bash', '--noprofile', '--norc', str(path)])
        self.env.pop('BASH_ENV', None)
        if result.returncode and any(role in ('guard', 'selection') for role in step_roles):
            with (self.root / 'command-trace.tsv').open('a') as trace:
                trace.write(f'{self.step}\tblock-error\t{result.returncode}\tguard/selection shell failed\n')
        self.shell_steps.append({'step': self.step, 'block_start': previous, 'block_end': self.block_cursor, 'block_ids': self.planned[previous:self.block_cursor], 'roles': step_roles, 'exit': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr})
        return result

    def check(self, name, passed, detail=''):
        self.checks.append({'name': name, 'pass': bool(passed), 'detail': detail})

    def selection(self, submit=False):
        return self.body('stack-submit' if submit else 'stack-test', 'STACK="descendants(')

    def stack(self):
        out = self.shell(self.selection(), 'printf "SCENARIO_STACK=%s\\n" "$STACK"')
        return next(x.split('=', 1)[1] for x in out.stdout.splitlines() if x.startswith('SCENARIO_STACK='))

    def selected(self):
        return self.selection(True) + '\nARGUMENTS=""\nSELECTED="$STACK"\n'

    def guard(self):
        selection = self.selection(True)
        body = self.body('stack-submit', 'SELECTED="$STACK"')
        # This documented block presents mutually exclusive default/argument examples.
        # Use the argument arm with HEAD, keeping the block verbatim.
        return selection + '\nARGUMENTS=HEAD\n' + body

    def snapshot(self):
        primary = self.root / 'P'
        porcelain = self.git('worktree', 'list', '--porcelain', cwd=primary)
        trees = {}
        for record in porcelain.split('\n\n'):
            lines = record.splitlines()
            if not lines:
                continue
            path = Path(lines[0].removeprefix('worktree '))
            if not path.exists():
                continue
            trees[str(path)] = {
                'head': self.git('rev-parse', 'HEAD', cwd=path),
                'branch': self.git('symbolic-ref', '-q', 'HEAD', cwd=path),
                'status': self.git('status', '--porcelain=v1', '--untracked-files=all', cwd=path),
                'index': self.git('ls-files', '--stage', cwd=path),
            }
        refs = self.git('for-each-ref', '--format=%(refname) %(objectname)', 'refs/heads', cwd=primary)
        refs = dict(line.split(' ', 1) for line in refs.splitlines())
        upstream = self.git('rev-parse', '--verify', 'refs/remotes/origin/main', cwd=primary)
        reachable = self.git('rev-list', upstream, cwd=primary).splitlines() if upstream else []
        upstream_trees = {sha: self.git('rev-parse', sha + '^{tree}', cwd=primary) for sha in reachable}
        database = primary / '.git/branchless/db.sqlite3'
        with sqlite3.connect('file:' + str(database) + '?mode=ro', uri=True) as conn:
            conn.row_factory = sqlite3.Row
            events = [dict(row) for row in conn.execute('SELECT rowid, * FROM event_log ORDER BY rowid')]
        upstream_diff = self.git('diff', '--name-status', upstream, 'HEAD', cwd=self.wt) if upstream else ''
        return {'trees': trees, 'refs': refs, 'upstream': upstream, 'upstream_trees': upstream_trees, 'events': events, 'upstream_diff': upstream_diff}

    def invariants(self):
        after = self.snapshot()
        own = str(self.wt)
        others = {p: s for p, s in self.before['trees'].items() if p != own}
        self.check('I1 other worktrees HEAD/branch/index/status unchanged', all(after['trees'].get(p) == s for p, s in others.items()))
        primary = str(self.root / 'P')
        self.check('I4 primary and main unchanged', self.before['trees'][primary] == after['trees'][primary] and self.before['refs']['refs/heads/main'] == after['refs'].get('refs/heads/main'))
        allowed = set(self.spec.get('allowed_deleted', []))
        deleted = set(self.before['refs']) - set(after['refs']) - allowed
        self.check('I6 no unexpected deleted branches', not deleted, ', '.join(sorted(deleted)))
        preserved = self.before['upstream'] == after['upstream'] and self.before['upstream_trees'] == after['upstream_trees']
        self.check('I2 upstream refs and reachable commit trees unchanged', preserved)
        prior_row = max((event['rowid'] for event in self.before['events']), default=0)
        public = set(self.before['upstream_trees'])
        new_events = [event for event in after['events'] if event['rowid'] > prior_row]
        unsafe = [event for event in new_events if event['old_ref'] in public and event['type'] in ('rewrite', 'obsolete', 'hide')]
        self.check('I2 no public commit rewritten or hidden', not unsafe, json.dumps(unsafe))
        base = self.before['upstream']
        if base:
            before_head = self.before['trees'][own]['head']
            fork = self.git('merge-base', base, before_head)
            own_paths = set(self.git('diff', '--name-only', fork, before_head).splitlines())
            upstream_entries = self.git('ls-tree', '-r', base).splitlines()
            lost = []
            integrated = self.cmd(['git', 'merge-base', '--is-ancestor', base, 'HEAD']).returncode == 0
            before_paths = set(self.git('ls-tree', '-r', '--name-only', before_head).splitlines())
            for entry in upstream_entries:
                metadata, file = entry.split('\t', 1)
                if file in own_paths or not integrated and file not in before_paths:
                    continue
                current = self.git('ls-tree', '-r', 'HEAD', '--', file)
                baseline = metadata if integrated else self.git('ls-tree', '-r', before_head, '--', file).split('\t')[0]
                if not current or current.split('\t')[0] != baseline:
                    lost.append(file)
            self.check('I2 upstream tree diff contains no unintended reverted paths', not lost, json.dumps({'lost': lost, 'before_diff': self.before['upstream_diff'], 'after_diff': after['upstream_diff']}))
        trace_path = self.root / 'command-trace.tsv'
        events = [line.split('\t', 3) for line in trace_path.read_text().splitlines()] if trace_path.exists() else []
        stopped = None
        violations = []
        for event in events:
            if event[1] in ('query-error', 'empty-selection', 'block-error'):
                stopped = event
            elif event[1] == 'mutator' and stopped:
                violations.append({'stop': stopped, 'mutator': event})
        self.check('I3 no mutator follows errored or empty guard/selection', not violations, json.dumps(violations))
        self.check('manifest ordered blocks consumed exactly', self.block_cursor == len(self.planned), f'{self.block_cursor}/{len(self.planned)}')
        (self.root / 'steps.json').write_text(json.dumps(self.shell_steps, indent=2))
        (self.root / 'I2-events.json').write_text(json.dumps({'public': sorted(public), 'new_events': new_events, 'unsafe': unsafe}, indent=2))
        (self.root / 'before.json').write_text(json.dumps(self.before, indent=2))
        (self.root / 'after.json').write_text(json.dumps(after, indent=2))


def exercise(c):
    kind = c.spec['kind']
    if kind == 'option-exists':
        doc = c.docs[PREFIX + 'references/git-branchless.md']
        claim = bool(re.search(r'In nix-agentic-tools, the `git\.branchless\.scopedSync` option', doc))
        definitions = sorted(path for path, source in c.sources.items()
                             if path.endswith('.nix') and re.search(r'scopedSync\s*=\s*(?:lib\.)?mk(?:Enable)?Option\b', source))
        c.check('static: no false claim about nonexistent module option', not claim or bool(definitions), f'claim_present={claim}; Nix option definitions={definitions!r}')
    elif kind == 'static':
        doc = c.docs[PREFIX + c.spec['path']]
        ok = bool(re.search(c.spec['pattern'], doc, re.M | re.S))
        c.check('static: ' + c.spec['expected']['description'], ok == c.spec.get('present', True))
    elif kind == 'static-set':
        doc = c.docs[PREFIX + c.spec['path']]
        for assertion in c.spec['assertions']:
            ok = bool(re.search(assertion['pattern'], doc, re.M | re.S))
            c.check('static: ' + assertion['id'], ok == assertion.get('present', True))
    elif kind == 'selection':
        result = c.shell(c.selected(), 'git query "$SELECTED"')
        expected = c.spec.get('subjects', ['a1', 'a2'])
        selected = c.git('query', '-r', c.stack()).splitlines()
        subjects = sorted(c.git('show', '-s', '--format=%s', h) for h in selected)
        c.check('endpoint: exact selected subjects', subjects == sorted(expected), repr(subjects))
        c.check('endpoint: selection shell success', result.returncode == 0)
    elif kind in ('guard-submit', 'guard-test', 'guard-unset', 'guard-merge', 'guard-localmain', 'guard-wide'):
        if kind in ('guard-submit', 'guard-merge', 'guard-localmain', 'guard-wide'):
            result = c.shell(c.guard())
            # First query lists selected commits by contract. Evaluate the relevant guard
            # separately so that the positive selection cannot masquerade as a stop.
            if kind == 'guard-merge':
                guard = result
            elif kind == 'guard-localmain':
                guard = c.shell(c.selected(), 'git query "only($SELECTED, $base) - ($STACK)"')
            elif kind == 'guard-wide':
                guard = c.shell(c.selected(), 'SELECTED="draft() - ::$base"\ngit query "only($SELECTED, $base) - ($STACK)"')
            else:
                guard = result
        else:
            selection = '' if kind == 'guard-unset' else c.selection()
            try:
                block = c.body('stack-test', '${STACK:?run the selection block first}')
            except RuntimeError:
                block = c.body('stack-test', '${STACK:?run the selection block first}')
            guard = c.shell(selection + block, replacements={'<revset>': '@' if kind == 'guard-unset' else '$STACK'})
        c.check('guard: detected prohibited rewrite or missing state', guard.returncode != 0 or bool(guard.stdout.strip()), f'rc={guard.returncode}; stdout={guard.stdout!r}; stderr={guard.stderr[-300:]!r}')
    elif kind in ('submit', 'hash-submit', 'untrack', 'tracking-preserve'):
        if kind == 'tracking-preserve':
            c.git('config', 'branch.a.merge', 'refs/heads/feature-a')
        body = c.selected()
        if kind == 'hash-submit':
            arg = c.git('rev-parse', 'HEAD')
            full = c.body('stack-submit', 'SELECTED="$STACK"')
            line = next(line for line in full.splitlines() if line.startswith('SELECTED=') and '$ARGUMENTS' in line)
            body += 'ARGUMENTS=' + shlex.quote(arg) + '\n' + line + '\n'
        if kind in ('submit', 'hash-submit'):
            body += c.body('stack-submit', 'git move -b "$SELECTED" -d "$upstream" || exit 1')
        body += c.body('stack-submit', 'for b in $(git query --branches "$SELECTED")')
        body += '\ngit config remote.pushDefault "$remote"\n'
        result = c.shell(body, 'git submit -c --dry-run "$SELECTED"' if kind != 'tracking-preserve' else 'git config branch.a.merge')
        if kind == 'tracking-preserve':
            c.check('endpoint: non-main tracking retained', 'refs/heads/feature-a' in result.stdout)
        else:
            c.check('endpoint: submission preview includes own stack', result.returncode == 0 and 'Would submit' in result.stdout, result.stdout[-500:])
            if kind in ('submit', 'hash-submit'):
                c.check('endpoint: own tip moved onto upstream', c.cmd(['git', 'merge-base', '--is-ancestor', 'origin/main', 'HEAD']).returncode == 0)
            if c.spec['id'] == 'HAPPY-submit':
                result = c.shell(c.selected() + c.body('stack-submit', 'git submit -c "$SELECTED"'))
                remote_head = c.git('--git-dir=' + str(c.root / 'origin.git'), 'rev-parse', 'refs/heads/a')
                c.check('endpoint: actual local bare-origin push', result.returncode == 0 and remote_head == c.git('rev-parse', 'a'))
    elif kind in ('fix-test', 'fix-cache'):
        formatter = c.root / 'fmt.sh'
        formatter.write_text(STRICT + 'for file in a1 a2; do\n  if [ -f "$file" ]; then printf "fixed\\n" > "$file"; fi\ndone\n')
        command = 'bash ' + str(formatter)
        stack = c.stack()
        c.git('config', 'branchless.test.strategy', 'worktree')
        if kind == 'fix-cache':
            c.cmd(['git', 'test', 'run', '--jobs', '1', '-x', command, stack], require=True)
        selection = c.selection()
        block = c.body('stack-test', 'git test fix ')
        result = c.shell(selection + block, replacements={'<revset>': stack, '<command>': command, '<N>': '1'})
        c.check('endpoint: test fix updates root and tip', c.git('show', 'a-1:a1') == 'fixed' and c.git('show', 'HEAD:a2') == 'fixed', result.stdout[-700:])
    elif kind in ('revise', 'revise-noop', 'revise-guard'):
        target = c.git('rev-parse', 'a-1')
        if kind == 'revise-guard':
            c.cmd(['git', 'worktree', 'add', '-q', '-b', 'review', str(c.root / 'wt-review'), target], require=True)
            c.before = c.snapshot()
        if kind != 'revise-noop':
            (c.wt / 'a1').write_text('a1 fixed\n')
            c.git('add', 'a1')
        pre = c.body('stack-fix', 'old_head="$(git rev-parse HEAD)"')
        if kind == 'revise-guard':
            result = c.shell(pre, replacements={'<target-hash>': target})
            c.check('guard: review worktree identified', 'review' in result.stdout)
        else:
            apply = c.body('stack-fix', 'git revise "$target"')
            repair = c.body('stack-fix', 'paste <(git rev-list')
            result = c.shell(pre + apply + repair, replacements={'<target-hash>': target})
            if kind == 'revise-noop':
                sl = c.git('sl')
                c.check('endpoint: no-op revise leaves live commits visible', '(manually hidden)' not in sl, sl[-700:])
            else:
                c.check('endpoint: revise moves intermediate branches and preserves tip', c.git('show', 'a-1:a1') == 'a1 fixed' and c.cmd(['git', 'merge-base', '--is-ancestor', 'a-1', 'HEAD']).returncode == 0)
    elif kind in ('absorb', 'children'):
        old = c.git('rev-parse', 'a-1')
        (c.wt / 'a1').write_text('a1 fixed\n')
        c.git('add', 'a1')
        if kind == 'absorb':
            if c.spec['id'].startswith('HAPPY'):
                c.git('config', 'rebase.updateRefs', 'true')
            block = c.body('stack-fix', 'git absorb --and-rebase --base')
            c.shell(block, replacements={'<target-commit>': old})
            c.check('endpoint: absorb updates intermediate branch', c.git('show', 'a-1:a1') == 'a1 fixed')
        else:
            c.cmd(['git', 'absorb', '--base', old + '^', '--and-rebase', '--', '--update-refs'], require=True)
            new = c.git('rev-parse', 'a-1')
            if "git move -s 'children(" not in c.docs[PREFIX + 'references/git-absorb.md']:
                c.check('static: newer children-repair regression absent at this revision', True)
                return
            block = c.body('git-absorb.md', "git move -s 'children(")
            command = next(line for line in block.splitlines() if line.startswith('git move -s'))
            result = c.shell(command, replacements={'<pre-rewrite-hash>': old, '<rewritten-hash>': new})
            c.check('guard: foreign fork not rewritten', result.returncode == 0 and '(manually hidden)' not in c.git('sl'), result.stderr[-500:])
    elif kind in ('summary', 'restructure'):
        if 'BASE="$(git merge-base "$base" HEAD)"' in c.docs[PREFIX + 'skills/stack-summary/SKILL.md']:
            block = c.body('stack-summary', 'BASE="$(git merge-base "$base" HEAD)"')
            # Select the documented Default alternative, not the Range/--root examples.
            block = block[block.index('# Default,'):]
        else:
            c.check('endpoint: executable own-stack default exists', False, 'Earlier revision has no executable default BASE/TIP selection; not invented by scenario tests.')
            return
        result = c.shell(block, 'printf "SCENARIO_BASE=%s\\n" "$BASE"')
        selected = next(line.split('=', 1)[1] for line in result.stdout.splitlines() if line.startswith('SCENARIO_BASE='))
        fork = c.git('merge-base', 'origin/main', 'HEAD')
        resolved = c.git('rev-parse', selected)
        c.check('endpoint: summary base equals true fork point', resolved == fork, f'base={selected} ({resolved}); fork={fork}')
        if kind == 'restructure':
            c.env['BASE'] = selected
            reset = c.body('stack-plan', 'git reset --soft $BASE').split('# From-root')[0]
            c.shell(reset)
            staged = c.git('diff', 'HEAD', '--name-status')
            c.check('endpoint: restructure stages no upstream deletion', 'D\tupstream2' not in staged, staged)
            c.git('add', '-A')
            c.git('commit', '-qm', 'restructure')
            c.check('endpoint: restructure preserves final own tree', c.git('show', 'HEAD:a1') == 'a1 old' and c.git('show', 'HEAD:a2') == 'a2 old')
    elif kind == 'hide':
        doc = c.docs[PREFIX + 'skills/stack-submit/SKILL.md']
        inline = re.search(r'`(git hide -r <hash>)`', doc)
        if not inline:
            raise RuntimeError('Inline hide recipe not found')
        target = c.git('rev-parse', 'a-1')
        c.shell(inline[1], replacements={'<hash>': target})
        c.check('endpoint: squash cleanup preserves live tip and branch', c.git('symbolic-ref', '-q', 'HEAD') == 'refs/heads/a' and '(manually hidden)' not in c.git('sl'))
    elif kind == 'squash-move':
        before = c.git('rev-parse', 'HEAD')
        result = c.shell(c.selected() + c.body('stack-submit', 'git move -b "$SELECTED" -d "$upstream" || exit 1'))
        overlap = c.env.get('SQUASH_COUNT') == 'multi' and c.env.get('SQUASH_OVERLAP') == 'yes'
        if overlap:
            c.check('endpoint: overlapping squash conflicts without moving tip', c.git('rev-parse', 'HEAD') == before and 'conflict' in (result.stdout + result.stderr).lower())
        else:
            c.check('endpoint: squash leaves only remaining open commit', c.git('rev-list', '--count', 'origin/main..HEAD') == '1' and c.git('show', 'HEAD:a3') != '')
    elif kind == 'start':
        block = c.body('git-branchless.md', 'git checkout --detach origin/main')
        # Recipe also contains illustrative edit/commit steps. Only its start command
        # is executable without inventing an application. Record that exact line.
        command = next(line for line in block.splitlines() if 'git checkout --detach origin/main' in line)
        c.shell(command)
        c.check('endpoint: new stack starts at latest upstream', c.git('rev-parse', 'HEAD') == c.git('rev-parse', 'origin/main'))
    elif kind == 'amend':
        c.cmd(['git', 'checkout', '-q', 'a-1'], require=True)
        (c.wt / 'a1').write_text('a1 fixed\n')
        c.git('add', 'a1')
        c.shell(c.body('stack-fix', '\ngit amend\n') if False else c.body('stack-fix', 'git amend\n'))
        c.git('checkout', '-q', 'a')
        c.check('endpoint: manual amend restacks own tip', c.git('show', 'a-1:a1') == 'a1 fixed' and c.git('show', 'HEAD:a1') == 'a1 fixed')
    elif kind == 'split':
        # Turn the tip into a two-file commit, then execute the skill's
        # interactive edit using a deterministic sequence editor.
        (c.wt / 'split-second').write_text('second\n')
        c.git('add', 'split-second')
        c.git('commit', '--amend', '--no-edit', '-q')
        tree = c.git('rev-parse', 'HEAD^{tree}')
        editor = c.root / 'editor.sh'
        editor.write_text(STRICT + 'sed -i "1s/^pick /edit /" "$1"\n')
        c.env['GIT_SEQUENCE_EDITOR'] = 'bash ' + str(editor)
        c.shell(c.body('stack-split', 'git rebase -i --update-refs'), replacements={'<commit>': 'HEAD'})
        c.shell(c.body('stack-split', 'git reset HEAD^'))
        group = c.body('stack-split', 'descriptive message for this group')
        for file in ('a2', 'split-second'):
            c.shell(group, replacements={'git add -p': 'git add ' + file, 'descriptive message for this group': 'split ' + file})
        c.shell(c.body('stack-split', 'git rebase --continue'))
        c.check('endpoint: split produces two commits with identical final tree', c.git('rev-parse', 'HEAD^{tree}') == tree and c.git('rev-list', '--count', 'a-1..HEAD') == '2')
    elif kind == 'recipe-move':
        block = c.body('git-branchless.md', 'own=')
        block += c.body('git-branchless.md', 'git move ')
        result = c.shell(block)
        c.check('endpoint: own stack reaches latest upstream', result.returncode == 0 and c.cmd(['git', 'merge-base', '--is-ancestor', 'origin/main', 'HEAD']).returncode == 0)
        c.check('endpoint: own commits retained', c.git('show', 'HEAD:a1') == 'a1 old' and c.git('show', 'HEAD:a2') == 'a2 old')
    elif kind == 'recipe-hide':
        target = c.git('rev-parse', 'a-1')
        block = c.body('git-branchless.md', 'git hide ')
        command = next(line for line in block.splitlines() if line.startswith('git hide '))
        result = c.shell(command, replacements={'<approach-A-hash>': target})
        after = c.snapshot()
        c.check('endpoint: hiding reviewed commit preserves every branch', result.returncode == 0 and after['refs'] == c.before['refs'])
        prior = max(event['rowid'] for event in c.before['events'])
        hidden = [event['old_ref'] for event in after['events'] if event['rowid'] > prior and event['type'] in ('hide', 'obsolete')]
        c.check('endpoint: only approach A is hidden', hidden == [target], repr(hidden))
    elif kind == 'recipe-restack':
        sibling = c.root / 'wt-b'
        old_b = c.git('rev-parse', 'HEAD', cwd=sibling)
        (sibling / 'b2').write_text('b2\n')
        c.cmd(['git', 'add', 'b2'], cwd=sibling, require=True)
        c.cmd(['git', 'commit', '-qm', 'b2'], cwd=sibling, require=True)
        c.cmd(['git', 'checkout', '--detach', old_b], cwd=sibling, require=True)
        (sibling / 'b1').write_text('b1 amended\n')
        c.cmd(['git', 'commit', '--amend', '-am', 'b1 amended'], cwd=sibling, require=True)
        c.cmd(['git', 'checkout', 'b'], cwd=sibling, require=True)
        old_a = c.git('rev-parse', 'a-1')
        c.cmd(['git', 'checkout', '--detach', old_a], require=True)
        (c.wt / 'a1').write_text('a1 amended\n')
        c.cmd(['git', 'commit', '--amend', '-am', 'a1 amended'], require=True)
        c.before = c.snapshot()
        result = c.shell(c.body('git-branchless.md', 'git restack '), replacements={'<abandoned-hash>': old_a})
        c.check('endpoint: scoped forced restack repairs own child', result.returncode == 0 and c.git('show', 'a:a1') == 'a1 amended')
        c.check('endpoint: sibling abandoned child remains on original parent', c.git('rev-parse', 'b^') == old_b)
    elif kind == 'safety-matrix':
        summary = c.body('stack-summary', 'BASE="$(git merge-base "$base" HEAD)"')
        summary = summary[summary.index('# Default,'):]
        result = c.shell(summary, 'printf "SCENARIO_BASE=%s\\n" "$BASE"')
        selected = next(line.split('=', 1)[1] for line in result.stdout.splitlines() if line.startswith('SCENARIO_BASE='))
        fork = c.git('merge-base', 'origin/main', 'HEAD')
        c.check('matrix: restructure base is the fork point', c.git('rev-parse', selected) == fork)

        submit_guard = c.shell(c.guard())
        should_stop = c.spec['topology'] in ('T2', 'T6', 'T9')
        c.check('matrix: submit guard handles sibling/stacked/detached topology', (submit_guard.returncode != 0) == should_stop, f'rc={submit_guard.returncode}')
        if should_stop:
            (c.root / 'command-trace.tsv').write_text('')

        test_selection = c.selection()
        test_guard = c.body('stack-test', '${STACK:?run the selection block first}')
        guard = c.shell(test_selection + test_guard, replacements={'<revset>': '@'})
        c.check('matrix: narrow test-fix selection is safe', guard.returncode == 0, guard.stderr[-500:])

        formatter = c.root / 'fmt-matrix.sh'
        formatter.write_text(STRICT + 'printf "matrix fixed\\n" > a2\n')
        command = 'bash ' + str(formatter)
        fix = c.body('stack-test', 'git test fix --strategy working-copy --jobs 1 --no-cache')
        fixed = c.shell(test_selection + fix, replacements={'<revset>': '@', '<command>': command})
        c.check('matrix: no-cache working-copy fix updates only the selected tip', fixed.returncode == 0 and c.git('show', 'HEAD:a2') == 'matrix fixed', fixed.stdout[-500:])
    else:
        raise RuntimeError('Unknown scenario kind: ' + kind)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('revision', nargs='?', help='optional revision read with git show')
    parser.add_argument('--repo', type=Path, help='checkout to read (default: this checkout)')
    parser.add_argument('--source-dir', type=Path, help='immutable repository source directory; never reads Git history')
    parser.add_argument('--output', type=Path, help='new directory for logs (default: a unique directory under TMPDIR)')
    parser.add_argument('--case', action='append', dest='case_ids', help='run just a named case; repeatable')
    args = parser.parse_args()
    if args.source_dir and args.revision:
        parser.error('--source-dir cannot be combined with a revision')
    start = time.monotonic()
    source = args.source_dir or args.repo
    if source is None:
        source = next((parent for parent in ROOT.parents if (parent / PREFIX).is_dir()), None)
        if source is None:
            parser.error('Supply --source-dir or --repo outside a checkout')
    source = source.resolve()
    docs, blocks = load(source, args.revision)
    if not blocks:
        parser.error('No shell blocks found in source')
    for tool in ('bash', 'git', 'git-absorb', 'git-branchless', 'git-revise'):
        if not shutil.which(tool):
            parser.error('Required tool missing from PATH: ' + tool)
    if args.output:
        run = args.output.resolve()
        run.mkdir(parents=True, exist_ok=False)
    else:
        run = Path(tempfile.mkdtemp(prefix='stack-scenarios-'))
    (run / 'blocks.json').write_text(json.dumps(blocks, indent=2))
    (run / 'source.json').write_text(json.dumps({'path': str(source), 'revision': args.revision}, indent=2))
    env = dict(os.environ, SCENARIO_REVISION=args.revision or '', SCENARIO_SOURCE=str(source))
    cases = [json.loads(path.read_text()) for path in sorted((ROOT / 'cases').glob('*.json'))]
    if args.case_ids:
        unknown = set(args.case_ids) - {case['id'] for case in cases}
        if unknown:
            parser.error('Unknown case IDs: ' + ', '.join(sorted(unknown)))
        cases = [case for case in cases if case['id'] in args.case_ids]
    if not cases:
        raise SystemExit('No cases found')

    results = []
    for spec in cases:
        case = None
        error = None
        try:
            case = Case(spec, run, docs, blocks, env)
            exercise(case)
        except Exception as exc:
            error = type(exc).__name__ + ': ' + str(exc)
            if case:
                case.check('scenario execution', False, error)
        finally:
            if case:
                try:
                    case.invariants()
                except Exception as exc:
                    case.check('invariant execution', False, str(exc))
                passed = not error and all(check['pass'] for check in case.checks)
                result = {'id': spec['id'], 'status': 'PASS' if passed else 'FAIL', 'checks': case.checks, 'block_ids': case.used, 'error': error}
                case.log.close()
            else:
                result = {'id': spec['id'], 'status': 'FAIL', 'checks': [], 'block_ids': [], 'error': error}
            case_dir = run / spec['id']
            case_dir.mkdir(exist_ok=True)
            (case_dir / 'result.json').write_text(json.dumps(result, indent=2))
        results.append(result)
        print(spec['id'] + ': ' + result['status'], flush=True)

    elapsed = time.monotonic() - start
    lines = [f'# Scenario results', '', f'Runtime: {elapsed:.1f} seconds. Logs: `{run}`.', '', '| Case | Result | Failed assertion / execution error |', '| --- | --- | --- |']
    for result in results:
        if result['status'] == 'PASS':
            continue
        detail = result['error'] or '; '.join(check['name'] + (': ' + check['detail'] if check['detail'] else '') for check in result['checks'] if not check['pass'])
        detail = detail.replace('|', '\\|').replace('\n', ' ')[:900]
        lines.append(f"| {result['id']} | {result['status']} | {detail} |")
    failed = sum(result['status'] == 'FAIL' for result in results)
    lines += ['', f'{len(results) - failed} PASS; {failed} FAIL.']
    report = '\n'.join(lines) + '\n'
    (run / 'RESULTS.md').write_text(report)
    (run / 'results.json').write_text(json.dumps(results, indent=2))
    print(report)
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
