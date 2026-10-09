#!/usr/bin/env python3
"""Bind one transport request to installed Kiro agents; never launch or call GitLab."""
import argparse
import hashlib
import json
import shlex
import sys
from pathlib import Path

import receipt

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT.parent))
from kiro.generate import agent_name, read_profile


def build(phase, profile, request_file, name):
    controls = profile['roles']['lens']
    configuration = receipt.check(phase, str(request_file))
    prompt = (ROOT / 'prompts' / f'{phase}.md').read_text()
    prompt += f'\n\nLocal API: {ROOT / "API.md"}\nHelper: {shlex.join([sys.executable, str(ROOT / "local.py")])}\n'
    prompt += f'Validated fixed request: {json.dumps(configuration)}\n'
    prompt += (ROOT / 'prompts' / 'native.md').read_text()

    def guard(terminal):
        command = [sys.executable, str(ROOT / 'receipt.py'), '--phase', phase, '--request', str(request_file), '--watch']
        if terminal:
            command.append('--terminal')
        return {'type': 'watch', 'id': 'verified-receipt' if terminal else 'preflight', 'handler': 'command',
                'config': {'command': shlex.join(command), 'commandTimeoutSec': 60, 'pollIntervalSec': 10,
                           'request_file': str(request_file), 'request_digest': configuration['request_digest'], 'binding': configuration.get('binding')}}

    return {'name': name, 'description': f'Standalone GitLab {phase}; one transport agent and local receipt guards.',
            'inputs': {}, 'injectOriginalUserRequest': False,
            'modelId': controls['model_id'], 'effortLevel': controls['effort'],
            'steps': [guard(False),
                      {'type': 'step', 'id': 'transport', 'agent': agent_name(phase, profile), 'prompt': prompt,
                       'captureOutput': True, 'modelId': controls['model_id'], 'effortLevel': controls['effort']},
                      guard(True)]}


def materialize(phase, profile_path, request_file, workspace):
    profile = read_profile(profile_path)
    key = hashlib.sha256(str(request_file).encode()).hexdigest()[:12]
    name = f'code-review-{phase}-{key}'
    recipe = build(phase, profile, request_file, name)
    destination = workspace / '.kiro' / 'workflows' / f'{name}.workflow.json'
    destination.parent.mkdir(parents=True, exist_ok=True)
    # A saved recipe binds its original request digest. Recovery uses that recipe;
    # regenerating over it would silently authorize a mutated request.
    with destination.open('x') as stream:
        stream.write(json.dumps(recipe, indent=2, sort_keys=True) + '\n')
    return {'name': name, 'request_file': str(request_file), 'workflow': str(destination)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', choices=('pull', 'push'), required=True)
    parser.add_argument('--profile', type=Path, required=True)
    parser.add_argument('--request', type=Path, required=True)
    parser.add_argument('--workspace', type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(materialize(args.phase, args.profile.resolve(strict=True), args.request.resolve(strict=True), args.workspace.resolve())))
        return 0
    except (KeyError, OSError, TypeError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
