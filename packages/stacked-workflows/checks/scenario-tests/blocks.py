#!/usr/bin/env python3
"""Extract fenced shell examples from a source tree or revision without executing them."""
import argparse
import collections
import json
import re
import subprocess
from pathlib import Path

PREFIX = 'packages/stacked-workflows/'


def sources(root, revision=None):
    """Read a checkout or immutable source directory; history is opt-in."""
    root = Path(root)
    if revision:
        paths = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', revision, PREFIX, 'packages/git-branchless/'], cwd=root, text=True).splitlines()
        return {path: subprocess.check_output(['git', 'show', f'{revision}:{path}'], cwd=root, text=True)
                for path in paths if path.endswith(('.md', '.nix'))}
    return {path.relative_to(root).as_posix(): path.read_text()
            for owner in ('stacked-workflows', 'git-branchless')
            for path in sorted((root / 'packages' / owner).rglob('*'))
            if path.is_file() and path.suffix in ('.md', '.nix')}


def load(repo, rev=None):
    documents, blocks = {}, {}
    for path, doc in sources(repo, rev).items():
        if not (path.startswith(PREFIX + 'references/') and path.endswith('.md') or path.startswith(PREFIX + 'skills/') and path.endswith('/SKILL.md')):
            continue
        documents[path] = doc
        heading, fence, body, counts, start = '(preamble)', None, [], collections.Counter(), 0
        for lineno, line in enumerate(doc.splitlines(), 1):
            match = re.match(r'^\s*(`{3,}|~{3,})(.*)$', line)
            if fence:
                if match and match[1][0] == fence[0] and len(match[1]) >= len(fence):
                    counts[heading] += 1
                    if language in ('bash', 'sh', 'shell', 'zsh'):
                        key = f'{path}::{heading}::{counts[heading]}'
                        # Markdown indentation is presentation, not shell content.
                        cleaned = '\n'.join(x[indent:] if x.startswith(' ' * indent) else x for x in body) + '\n'
                        blocks[key] = {'id': key, 'path': path, 'heading': heading, 'ordinal': counts[heading], 'line': start, 'body': cleaned}
                    fence, body = None, []
                else:
                    body.append(line)
            elif match:
                fence, language, indent, start = match[1], match[2].strip(), len(line) - len(line.lstrip()), lineno + 1
            elif re.match(r'^#{1,6} ', line):
                heading = line.lstrip('#').strip()
    return documents, blocks


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('repo')
    parser.add_argument('--revision')
    parser.add_argument('id', nargs='?')
    args = parser.parse_args()
    _, available = load(args.repo, args.revision)
    if args.id is None:
        print(json.dumps(list(available.values()), indent=2))
    elif args.id not in available:
        parser.error('Unknown block ID: ' + args.id + '\nAvailable:\n' + '\n'.join(available))
    else:
        print(available[args.id]['body'], end='')
