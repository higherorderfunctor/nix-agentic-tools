#!/usr/bin/env python3
"""Validate transport inputs and bind local terminal receipts; never remote I/O."""
import argparse
import hashlib
import json
import re
import sys
from pathlib import Path

import local


def absolute(value, name):
    local.require(isinstance(value, str) and Path(value).is_absolute(), f'{name} must be an absolute path')
    return Path(value)


def check(phase, request_file, terminal=False, request_digest=None, binding=None):
    request_path = absolute(str(request_file), 'request_file')
    raw = request_path.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    local.require(request_digest is None or digest == request_digest, 'request changed since launch')
    request = json.loads(raw)
    local.require(request.get('schema_version') == 1, 'request must have schema_version 1')
    transport = request.get('transport', 'glab')
    local.require(transport in ('glab', 'mcp'), 'transport must be glab or mcp')
    if transport == 'mcp':
        local.require(isinstance(request.get('mcp_server'), str) and request['mcp_server']
                      and isinstance(request.get('mcp_tools'), list) and request['mcp_tools']
                      and all(isinstance(name, str) and name for name in request['mcp_tools']),
                      'MCP transport needs configured server and actual tool names')
    target = request.get('target', {})
    local.require(isinstance(target.get('host'), str) and re.fullmatch(r'[A-Za-z0-9.-]+(?::[0-9]+)?', target['host']), 'explicit target host required')
    for key in ('project_id', 'mr_iid'):
        local.require(isinstance(target.get(key), str) and re.fullmatch(r'[1-9][0-9]*', target[key]), f'target.{key} must be a positive decimal string')
    absolute(request.get('snapshot'), 'snapshot')
    result = {'request_file': str(request_path), 'request_digest': digest, 'request': request}
    if phase == 'pull':
        checkout = absolute(request.get('checkout'), 'checkout')
        output = absolute(request.get('output_dir'), 'output_dir')
        local.require(not output.resolve().is_relative_to(checkout.resolve()), 'output_dir must be outside checkout')
        if 'intake_output' in request:
            absolute(request['intake_output'], 'intake_output')
        for key in ('house_rules', 'intake', 'prior_snapshot'):
            if key in request:
                absolute(request[key], key).read_bytes()
        if output.exists():
            receipt = local.verify_freeze(argparse.Namespace(frozen_dir=str(output)))
            for key in ('host', 'project_id', 'mr_iid'):
                local.require(receipt['hashes']['target'][key] == target[key], 'frozen target differs from request')
            bundle = local.read(receipt['bundle'])
            local.require(Path(bundle['checkout']).resolve() == checkout.resolve(), 'frozen checkout differs from request')
            local.require(Path(receipt['bundle']).parent.resolve() == output.resolve(), 'frozen output_dir differs')
            if 'house_rules' in request:
                local.require(bundle['house_rules'] == local.read(request['house_rules']), 'frozen house_rules differ')
            frozen_claims = local.read(receipt['intake'])
            if 'intake' in request:
                supplied = local.read(request['intake'])
                local.require(all(claim in frozen_claims['claims'] for claim in supplied['claims']), 'supplied intake was dropped')
            if 'intake_output' in request:
                local.require(frozen_claims == local.read(request['intake_output']), 'generated intake differs from frozen artifact')
            result['receipt'] = receipt
        elif terminal:
            raise ValueError('missing frozen receipt')
    else:
        publication = absolute(request.get('publication_dir'), 'publication_dir')
        absolute(request.get('observation_file'), 'observation_file')
        snapshot = local.snapshot(request['snapshot'])
        for key in ('host', 'project_id', 'mr_iid'):
            local.require(snapshot['target'][key] == target[key], 'snapshot target differs')
        report_path = absolute(request.get('report_json'), 'report_json')
        markdown_path = absolute(request.get('report_md'), 'report_md')
        report_bytes = report_path.read_bytes()
        markdown_bytes = markdown_path.read_bytes()
        report = json.loads(report_bytes)
        local.require(report.get('schema_version') == 1 and report.get('status', {}).get('complete') is True, 'selected report is incomplete')
        local.require(report['target'] == {'id': local.target_id(snapshot['target']), 'base_sha': snapshot['target']['base_sha'], 'head_sha': snapshot['target']['head_sha']}, 'selected report target differs')
        local.require(request.get('action') in ('create', 'reply', 'update'), 'action must be create/reply/update')
        if request['action'] != 'create':
            local.require(isinstance(request.get('discussion_id'), str) and request['discussion_id'], 'discussion_id required')
        if request['action'] == 'update':
            for key in ('note_id', 'owner_id'):
                local.require(isinstance(request.get(key), str) and request[key], f'{key} required for update')
            local.require(isinstance(request.get('baseline_hash'), str) and re.fullmatch(r'[0-9a-f]{64}', request['baseline_hash']), 'baseline_hash required for update')
        else:
            local.require(not any(key in request for key in ('note_id', 'owner_id', 'baseline_hash')), 'update-only fields forbidden')
        expected = {'target': snapshot['target'], 'action': request['action'],
                    'report_json_sha256': local.sha(report_bytes), 'report_md_sha256': local.sha(markdown_bytes),
                    'input_digest': report['provenance']['input_digest']}
        local.require(binding is None or binding == expected, 'selected report artifacts changed since launch')
        result['binding'] = expected
        if publication.exists():
            status = local.status(argparse.Namespace(publication_dir=str(publication)))
            local.require(all(status.get(key) == value for key, value in expected.items()), 'existing publication belongs to another request/report')
            # status validates the sealed plan; bind the remaining chosen sink fields too.
            plan = local.read(publication / 'plan.json')
            for key in ('discussion_id', 'note_id', 'baseline_hash', 'owner_id'):
                local.require(plan.get(key) == request.get(key), f'publication {key} differs')
            if terminal:
                local.require(status.get('state') == 'verified' and isinstance(status.get('receipt'), dict), 'publication is not verified')
            result['receipt'] = status
        elif terminal:
            raise ValueError('missing publication receipt')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--phase', choices=('pull', 'push'), required=True)
    parser.add_argument('--request', required=True)
    parser.add_argument('--request-digest')
    parser.add_argument('--binding')
    parser.add_argument('--terminal', action='store_true')
    parser.add_argument('--watch', action='store_true')
    args = parser.parse_args()
    try:
        if args.watch:
            config = json.load(sys.stdin)['config']
            result = check(args.phase, config['request_file'], args.terminal, config['request_digest'], config.get('binding'))
            print(json.dumps({'outcome': 'terminal-state', 'cursor': None, 'payload': json.dumps(result)}))
        else:
            print(json.dumps(check(args.phase, args.request, args.terminal, args.request_digest, json.loads(args.binding) if args.binding else None)))
        return 0
    except (KeyError, OSError, ValueError, TypeError) as error:
        print(str(error), file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
