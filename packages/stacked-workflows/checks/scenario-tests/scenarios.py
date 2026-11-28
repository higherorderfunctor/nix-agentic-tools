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
        self.behavioral = spec['kind'] not in ('option-exists', 'static', 'static-set')
        if self.behavioral:
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

    def selected_subjects(self, result):
        if result.returncode:
            return None
        return sorted(self.cmd(['git', 'show', '-s', '--format=%s', commit], require=True).stdout.strip()
                      for commit in result.stdout.split())

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
        # I1 already compares the primary worktree unless it is the caller.
        if primary == own:
            self.check('I4 primary worktree HEAD/branch/index/status unchanged', self.before['trees'][primary] == after['trees'][primary])
        # The hide recipe's endpoint already compares the complete ref map.
        if self.spec['kind'] != 'recipe-hide':
            allowed = set(self.spec.get('allowed_deleted', []))
            deleted = set(self.before['refs']) - set(after['refs']) - allowed
            self.check('I6 no unexpected deleted branches', not deleted, ', '.join(sorted(deleted)))
        self.check('I2 upstream tip unchanged', self.before['upstream'] == after['upstream'])
        prior_row = max((event['rowid'] for event in self.before['events']), default=0)
        public = set(self.before['upstream_trees'])
        new_events = [event for event in after['events'] if event['rowid'] > prior_row]
        unsafe = [event for event in new_events if event['old_ref'] in public and event['type'] in ('rewrite', 'obsolete', 'hide')]
        self.check('I2 no public commit rewritten or hidden', not unsafe, json.dumps(unsafe))
        base = self.before['upstream']
        # The squash-move endpoint already pins the complete diff from upstream.
        if base and self.spec['kind'] != 'squash-move':
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
            if event[1] == 'workflow-boundary':
                stopped = None
            elif event[1] in ('query-error', 'empty-selection', 'block-error'):
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
        expected = sorted(c.spec.get('subjects', ['a1', 'a2']))
        # The two skills publish independent selectors. Neither one's output
        # can stand in for the other's, even when the fixture is empty.
        for skill, submit in (('submit', True), ('test', False)):
            result = c.shell(c.selection(submit), 'git query -r "$STACK"')
            subjects = c.selected_subjects(result)
            c.check(f'{skill}: selects exactly the fixture commits',
                    subjects == expected, f'expected={expected!r}; got={subjects!r}; stderr={result.stderr!r}')
    elif kind == 'guard-unset':
        block = c.body('stack-test', '<revset>')
        guard = c.shell('unset STACK\n' + block, replacements={'<revset>': '@'})
        c.check('guard: missing selection state stops with instructions to run the selection block',
                guard.returncode != 0 and not guard.stdout and 'STACK: run the selection block first' in guard.stderr,
                f'rc={guard.returncode}; stdout={guard.stdout!r}; stderr={guard.stderr!r}')
    elif kind == 'guard-merge':
        guard = c.shell(c.guard())
        c.check('guard: detected prohibited rewrite or missing state', guard.returncode != 0 or bool(guard.stdout.strip()), f'rc={guard.returncode}; stdout={guard.stdout!r}; stderr={guard.stderr[-300:]!r}')
    elif kind in ('hash-submit', 'preview-tracking', 'submit'):
        if kind == 'preview-tracking':
            c.git('config', 'branch.a.merge', 'refs/heads/feature-a')
        body = c.selected()
        if kind == 'hash-submit':
            arg = c.git('rev-parse', 'HEAD')
            full = c.body('stack-submit', 'SELECTED="$STACK"')
            line = next(line for line in full.splitlines() if line.startswith('SELECTED=') and '$ARGUMENTS' in line)
            body += 'ARGUMENTS=' + shlex.quote(arg) + '\n' + line + '\n'
        body += c.body('stack-submit', 'lease_heads=')
        if kind in ('hash-submit', 'submit'):
            body += c.body('stack-submit', 'git move -b "$SELECTED" -d "$upstream" || exit 1')
        body += c.body('stack-submit', 'push_selected --dry-run')
        publish = c.spec['id'] == 'HAPPY-submit'
        if publish:
            body += c.body('stack-submit', 'push_selected\n')
        result = c.shell(body)
        if kind == 'preview-tracking':
            c.check('endpoint: preview succeeds and retains non-main tracking', result.returncode == 0 and c.git('config', 'branch.a.merge') == 'refs/heads/feature-a', result.stderr[-500:])
        else:
            # A real push can print the same ref update as the preview.
            if not publish:
                c.check('endpoint: submission preview includes own stack', result.returncode == 0 and 'a -> a' in result.stderr, result.stderr[-500:])
            if kind in ('hash-submit', 'submit'):
                c.check('endpoint: own tip moved onto upstream', c.cmd(['git', 'merge-base', '--is-ancestor', 'origin/main', 'HEAD']).returncode == 0)
            if publish:
                remote_head = c.git('--git-dir=' + str(c.root / 'origin.git'), 'rev-parse', 'refs/heads/a')
                c.check('endpoint: actual local bare-origin push', result.returncode == 0 and remote_head == c.git('rev-parse', 'a'))
                c.check('endpoint: push replaces inherited main tracking', c.git('config', 'branch.a.merge') == 'refs/heads/a')
    elif kind == 'first-push-main':
        c.wt = c.root / 'P'
        c.check('fixture: main is checked out', c.git('symbolic-ref', 'HEAD') == 'refs/heads/main')
        for branch, commit in (('feat/a', 'main~2'), ('feat/b', 'main~1')):
            c.cmd(['git', 'branch', branch, commit], require=True)
        body = STRICT + 'remote=origin\n'
        body += c.body('stack-submit', "SELECTED='feat/a")
        body += c.body('stack-submit', 'lease_heads=')
        body += c.body('stack-submit', 'push_selected --dry-run')
        body += c.body('stack-submit', 'push_selected\n')
        result = c.shell(body)
        c.check('endpoint: first push from main succeeds', result.returncode == 0, result.stderr[-1200:])
        published = c.git('ls-remote', '--heads', 'origin').splitlines()
        c.check('endpoint: exactly the two explicit branches are published',
                sorted(published) == sorted(c.git('rev-parse', branch) + '\trefs/heads/' + branch
                                            for branch in ('feat/a', 'feat/b')), repr(published))
        for branch in ('feat/a', 'feat/b'):
            c.check('endpoint: tracking matches ' + branch,
                    c.git('config', 'branch.' + branch + '.remote') == 'origin'
                    and c.git('config', 'branch.' + branch + '.merge') == 'refs/heads/' + branch)
    elif kind == 'pinned-submit':
        mode = c.spec['args']['mode']
        origin = c.root / 'origin.git'
        existing = mode in ('stale', 'stale-fetch', 'update')
        if existing:
            c.cmd(['git', 'push', '-u', 'origin', 'a'], require=True)
        competitor = c.root / 'up'
        if mode in ('stale', 'stale-fetch'):
            c.cmd(['git', 'fetch', 'origin', 'a'], cwd=competitor, require=True)
            c.cmd(['git', 'checkout', '--detach', 'FETCH_HEAD'], cwd=competitor, require=True)
            (competitor / 'concurrent').write_text('another writer\n')
            c.cmd(['git', 'add', 'concurrent'], cwd=competitor, require=True)
            c.cmd(['git', 'commit', '-m', 'concurrent update'], cwd=competitor, require=True)
        competing_tip = c.git('rev-parse', 'HEAD', cwd=competitor)
        before_tip = c.git('rev-parse', 'HEAD')
        body = STRICT + c.selected() + c.body('stack-submit', 'lease_heads=')
        body += c.body('stack-submit', 'git move -b "$SELECTED" -d "$upstream" || exit 1')
        if mode == 'create':
            # Production step 6 may name a branch after the initial move and snapshot.
            body += '\ngit branch named-after-move HEAD\n'
        racing = mode in ('create-race', 'stale', 'stale-fetch')
        if racing:
            body += '\ngit -C ' + shlex.quote(str(competitor)) + ' push origin HEAD:refs/heads/a\n'
        if mode == 'stale-fetch':
            # Reproduce a fetch by this or another worktree after the rewrite.
            body += '\ngit fetch origin\n'
        body += c.body('stack-submit', 'push_selected\n')
        result = c.shell(body)
        remote_tip = c.git('--git-dir=' + str(origin), 'rev-parse', 'refs/heads/a')
        c.check('endpoint: production move rewrote the published tip', c.git('rev-parse', 'HEAD') != before_tip)
        if racing:
            c.check('endpoint: competing remote tip is preserved', remote_tip == competing_tip,
                    f'remote={remote_tip}; competing={competing_tip}')
            c.check('endpoint: stale or absent lease is rejected', result.returncode != 0 and 'stale info' in result.stderr,
                    result.stderr[-1200:])
            if mode == 'stale-fetch':
                c.check('endpoint: fetch really advanced the shared tracking ref',
                        c.git('rev-parse', 'origin/a') == competing_tip)
            if mode == 'create-race':
                c.check('endpoint: competing creation would permit an ordinary fast-forward',
                        c.cmd(['git', 'merge-base', '--is-ancestor', competing_tip, 'a']).returncode == 0)
        else:
            c.check('endpoint: pinned publication succeeds', result.returncode == 0, result.stderr[-1200:])
            branches = ['a', 'a-1'] + (['named-after-move'] if mode == 'create' else [])
            for branch in branches:
                c.check('endpoint: remote and tracking match ' + branch,
                        c.git('--git-dir=' + str(origin), 'rev-parse', 'refs/heads/' + branch) == c.git('rev-parse', branch)
                        and c.git('config', 'branch.' + branch + '.merge') == 'refs/heads/' + branch)
    elif kind == 'fix-cache':
        formatter = c.root / 'fmt.sh'
        formatter.write_text(STRICT + 'for file in a1 a2; do\n  if [ -f "$file" ]; then printf "fixed\\n" > "$file"; fi\ndone\n')
        command = 'bash ' + str(formatter)
        stack = c.stack()
        c.git('config', 'branchless.test.strategy', 'worktree')
        c.cmd(['git', 'test', 'run', '--jobs', '1', '-x', command, stack], require=True)
        common = Path(c.git('rev-parse', '--path-format=absolute', '--git-common-dir'))
        for ref in ('a-1', 'HEAD'):
            tree = c.git('rev-parse', ref + '^{tree}')
            c.check(f'fixture: worktree run cached the formatter result for {ref}',
                    bool(tree) and (common / 'branchless' / 'test' / tree).is_dir())
        block = c.body('stack-test', 'git test fix ')
        result = c.shell(block, replacements={'<revset>': stack, '<command>': command, '<N>': '1'})
        c.check('endpoint: formatter rewrites both commits even after a cached worktree run',
                result.returncode == 0 and c.git('show', 'a-1:a1') == 'fixed' and c.git('show', 'HEAD:a2') == 'fixed',
                (result.stdout + result.stderr)[-700:])
    elif kind == 'absorb':
        old = c.git('rev-parse', 'a-1')
        (c.wt / 'a1').write_text('a1 fixed\n')
        c.git('add', 'a1')
        if c.spec['id'].startswith('HAPPY'):
            c.git('config', 'rebase.updateRefs', 'true')
        block = c.body('stack-fix', 'git absorb --and-rebase --base')
        c.shell(block, replacements={'<target-commit>': old})
        c.check('endpoint: absorb updates intermediate branch', c.git('show', 'a-1:a1') == 'a1 fixed')
    elif kind == 'restructure':
        block = c.body('stack-summary', 'BASE="$(git merge-base "$base" HEAD)"')
        # Select the documented Default alternative, not the Range/--root examples.
        block = block[block.index('# Default,'):]
        result = c.shell(block, 'printf "SCENARIO_BASE=%s\\n" "$BASE"')
        selected = next(line.split('=', 1)[1] for line in result.stdout.splitlines() if line.startswith('SCENARIO_BASE='))
        # The fixture branches a-1 directly from upstream1, even when
        # origin/main has since advanced. Do not repeat the skill's merge-base.
        fork = c.git('rev-parse', 'a-1^')
        resolved = c.git('rev-parse', selected)
        c.check('endpoint: summary base equals true fork point', resolved == fork, f'base={selected} ({resolved}); fork={fork}')
        c.env['BASE'] = selected
        reset = c.body('stack-plan', 'git reset --soft $BASE').split('# From-root')[0]
        c.shell(reset)
        staged = c.git('diff', 'HEAD', '--name-status')
        c.check('endpoint: restructure stages no upstream deletion', 'D\tupstream2' not in staged, staged)
        c.git('add', '-A')
        c.git('commit', '-qm', 'restructure')
        c.check('endpoint: restructure preserves final own tree', c.git('show', 'HEAD:a1') == 'a1 old' and c.git('show', 'HEAD:a2') == 'a2 old')
    elif kind == 'squash-move':
        result = c.shell(c.selected() + c.body('stack-submit', 'selection became empty'))
        output = result.stdout + result.stderr
        expected = c.spec['expected']
        if expected.get('conflict'):
            stopped = c.snapshot()
            conflict = (result.returncode == 1 and 'conflict' in output.lower()
                        and stopped['trees'][str(c.wt)] == c.before['trees'][str(c.wt)]
                        and stopped['refs'] == c.before['refs'])
            c.check('ordinary move: overlapping squash stops on a conflict and preserves the own worktree and refs',
                    conflict, output[-900:])
            if not conflict:
                return
            with (c.root / 'command-trace.tsv').open('a') as trace:
                trace.write(f'{c.step}\tworkflow-boundary\t0\tstart the separate scoped recovery recipe\n')
            # The same overlapping squash must succeed when using the documented
            # post-squash recipe: moving only a3 avoids replaying either f edit.
            selection = c.selection(True)
            remaining = c.body('stack-submit', 'first="<first remaining commit>"')
            move = c.body('stack-submit', 'git move --dry-run -s "$first"')
            result = c.shell(selection + remaining + move, replacements={'<first remaining commit>': 'HEAD'})
        else:
            c.check('ordinary move: drops the squashed patch for the documented reason',
                    expected['skip'] in output, output[-900:])
        subjects = c.git('log', '--format=%s', 'origin/main..HEAD').splitlines()
        c.check('endpoint: only the open commit remains directly on the squash, with its patch intact',
                result.returncode == 0 and subjects == ['a3']
                and c.git('rev-parse', 'HEAD^') == c.git('rev-parse', 'origin/main')
                and c.git('diff', '--name-status', 'origin/main', 'HEAD') == 'A\ta3'
                and c.git('show', 'HEAD:a3') == 'a3 content', repr(subjects))
    elif kind == 'start':
        block = c.body('git-branchless.md', 'git checkout --detach origin/main')
        # Recipe also contains illustrative edit/commit steps. Only its start command
        # is executable without inventing an application. Record that exact line.
        command = next(line for line in block.splitlines() if 'git checkout --detach origin/main' in line)
        c.shell(command)
        c.check('endpoint: new stack starts at latest upstream', c.git('rev-parse', 'HEAD') == c.git('rev-parse', 'origin/main'))
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
        subjects = c.git('log', '--reverse', '--format=%s', 'a-1..HEAD').splitlines()
        c.check('endpoint: split produces the two approved groups in order without changing the final tree',
                subjects == ['split a2', 'split split-second'] and c.git('rev-parse', 'HEAD^{tree}') == tree,
                repr(subjects))
    elif kind == 'recipe-move':
        block = c.body('git-branchless.md', 'own=')
        block += c.body('git-branchless.md', 'git move ')
        result = c.shell(block)
        c.check('endpoint: own stack reaches latest upstream', result.returncode == 0 and c.cmd(['git', 'merge-base', '--is-ancestor', 'origin/main', 'HEAD']).returncode == 0)
        subjects = c.git('log', '--reverse', '--format=%s', 'origin/main..HEAD').splitlines()
        c.check('endpoint: move retains just the two own commits, in order, with their changes intact',
                subjects == ['a1', 'a2'] and c.git('show', 'HEAD:a1') == 'a1 old'
                and c.git('show', 'HEAD:a2') == 'a2 old', repr(subjects))
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
        new_b = c.git('rev-parse', 'HEAD', cwd=sibling)
        c.cmd(['git', 'checkout', 'b'], cwd=sibling, require=True)
        c.check('fixture: sibling has an independent abandoned child that an unscoped restack could move',
                old_b != new_b and c.git('rev-parse', 'b^') == old_b)
        old_a = c.git('rev-parse', 'a-1')
        c.cmd(['git', 'checkout', '--detach', old_a], require=True)
        (c.wt / 'a1').write_text('a1 amended\n')
        c.cmd(['git', 'commit', '--amend', '-am', 'a1 amended'], require=True)
        new_a = c.git('rev-parse', 'HEAD')
        c.before = c.snapshot()
        result = c.shell(c.body('git-branchless.md', 'git restack '), replacements={'<abandoned-hash>': old_a})
        # I1 also checks the sibling's HEAD, which pins its immutable parent.
        c.check('endpoint: forced restack reattaches the own child to the rewritten parent',
                result.returncode == 0 and c.git('rev-parse', 'a^') == new_a and c.git('show', 'a:a1') == 'a1 amended')
    elif kind == 'safety-matrix':
        worktree = c.spec['expected'].get('overlap_worktree')
        # The guard can print the same HEAD for several selected ancestors.
        expected_heads = {c.git('rev-parse', 'HEAD', cwd=c.root / worktree)} if worktree else set()
        if c.spec['expected'].get('tip_fix'):
            test_selection = c.selection()
            test_guard = c.body('stack-test', '${STACK:?run the selection block first}')
            formatter = c.root / 'fmt-matrix.sh'
            formatter.write_text(STRICT + 'printf "matrix fixed\\n" > a2\n')
            fix = c.body('stack-test', 'git test fix --strategy working-copy --jobs 1 --no-cache')
            before_root = c.git('rev-parse', 'a-1')
            # A whole-stack rewrite is unsafe here, but the other worktree has
            # no descendant of @. On guard failure, never enter the fix block.
            fixed = c.shell(test_selection + '(\n' + test_guard + ') || exit $?\n' + fix,
                            replacements={'<revset>': '@', '<command>': 'bash ' + str(formatter)})
            c.check('test: fixing only the tip is safe above a shared stack root',
                    fixed.returncode == 0 and c.git('show', 'HEAD:a2') == 'matrix fixed'
                    and c.git('rev-parse', 'a-1') == before_root and c.git('rev-parse', 'HEAD^') == before_root,
                    (fixed.stdout + fixed.stderr)[-500:])
        submit_guard = c.shell(c.guard())
        c.check('submit: reports exactly the stacked worktree HEAD, or allows the disjoint sibling',
                submit_guard.returncode == (1 if worktree else 0)
                and set(submit_guard.stdout.split()) == expected_heads,
                f'expected={sorted(expected_heads)!r}; rc={submit_guard.returncode}; stdout={submit_guard.stdout!r}; stderr={submit_guard.stderr!r}')
        if c.spec['expected'].get('test_overlap'):
            test_selection = c.selection()
            test_guard = c.body('stack-test', '${STACK:?run the selection block first}')
            guard = c.shell(test_selection + test_guard, replacements={'<revset>': '$STACK'})
            c.check('test: a detached worktree also blocks a full-stack fix',
                    guard.returncode == 1 and set(guard.stdout.split()) == expected_heads,
                    f'expected={sorted(expected_heads)!r}; rc={guard.returncode}; stdout={guard.stdout!r}; stderr={guard.stderr!r}')
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
                if case.behavioral:
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
