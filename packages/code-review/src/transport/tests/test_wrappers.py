"""Native wrapper generation and artifact binding, without remote/model calls."""
import argparse
import copy
import json
import os
import sys
import subprocess
import shlex
import unittest
from pathlib import Path

sys.path.insert(0, os.environ.get('CODE_REVIEW_TRANSPORT', str(Path(__file__).resolve().parents[1])))
import materialize
from kiro.generate import ROLES
import receipt
import test_local


class WrapperTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_local.TransportTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        f = self.fixture
        self.request_path = f.root / 'request.json'
        self.target = {key: f.value['target'][key] for key in ('host', 'project_id', 'mr_iid')}
        self.pull = {'schema_version': 1, 'target': self.target, 'snapshot': str(f.snapshot_path),
                     'checkout': str(f.checkout), 'output_dir': str(f.root / 'frozen')}
        self.push = {'schema_version': 1, 'target': self.target, 'snapshot': str(f.snapshot_path),
                     'report_json': str(f.report_path), 'report_md': str(f.md), 'publication_dir': str(f.pub),
                     'observation_file': str(f.root / 'fresh.json'), 'action': 'create'}

    def store(self, request):
        self.request_path.write_text(json.dumps(request))

    def test_mcp_selection_requires_actual_configuration(self):
        self.store({**self.pull, 'transport': 'mcp'})
        with self.assertRaisesRegex(ValueError, 'configured server'):
            receipt.check('pull', self.request_path)
        request = {**self.pull, 'transport': 'mcp', 'mcp_server': 'configured-gitlab',
                   'mcp_tools': ['@configured-gitlab/get_merge_request']}
        self.store(request)
        self.assertEqual(receipt.check('pull', self.request_path)['request'], request)

    def test_pull_checks_resume_identity_and_changed_request(self):
        self.store(self.pull)
        first = receipt.check('pull', self.request_path)
        with self.assertRaisesRegex(ValueError, 'missing frozen'):
            receipt.check('pull', self.request_path, True)
        f = self.fixture
        receipt.local.freeze(argparse.Namespace(snapshot=str(f.snapshot_path), checkout=str(f.checkout),
                           output_dir=self.pull['output_dir'], house_rules=None, intake=None))
        self.assertEqual(receipt.check('pull', self.request_path, True)['receipt']['state'], 'frozen')
        wrong = copy.deepcopy(self.pull)
        wrong['target']['mr_iid'] = '99'
        self.store(wrong)
        with self.assertRaisesRegex(ValueError, 'target differs'):
            receipt.check('pull', self.request_path)
        with self.assertRaisesRegex(ValueError, 'request changed'):
            receipt.check('pull', self.request_path, True, first['request_digest'])

    def test_push_binds_existing_plan_before_agent_and_terminal_receipt(self):
        f = self.fixture
        self.store(self.push)
        initial = receipt.check('push', self.request_path)
        f.md.write_text('Changed before any publication plan')
        with self.assertRaisesRegex(ValueError, 'changed since launch'):
            receipt.check('push', self.request_path, binding=initial['binding'])
        f.md.write_bytes(b'# Complete report\r\n\r\nNo accepted findings.\r\n')
        f.plan()
        with self.assertRaisesRegex(ValueError, 'not verified'):
            receipt.check('push', self.request_path, True)
        f.value['discussions'] = [f.note(receipt.local.read(f.pub / 'plan.json')['body'])]
        f.observe()
        self.assertEqual(receipt.check('push', self.request_path, True)['receipt']['state'], 'verified')
        f.md.write_text('A different selected report')
        with self.assertRaisesRegex(ValueError, 'another request/report'):
            receipt.check('push', self.request_path)

    def test_push_rejects_wrong_upfront_target_and_update_fields(self):
        self.store({**self.push, 'action': 'update'})
        with self.assertRaisesRegex(ValueError, 'discussion_id'):
            receipt.check('push', self.request_path)
        wrong = copy.deepcopy(self.push)
        wrong['target']['project_id'] = '99'
        self.store(wrong)
        with self.assertRaisesRegex(ValueError, 'snapshot target differs'):
            receipt.check('push', self.request_path)

    def test_saved_recipes_bind_requests_to_installed_agents(self):
        profile = {'roles': {role: {'model_id': 'fixture-model', 'effort': 'medium'} for role in ROLES}, 'limits': {'concurrency': 6, 'max_waves': 3}}
        profile_path = self.fixture.root / 'profile.json'
        profile_path.write_text(json.dumps(profile))
        for phase, request in [('pull', self.pull), ('push', self.push)]:
            self.store(request)
            workspace = self.fixture.root / phase
            result = materialize.materialize(phase, profile_path, self.request_path, workspace)
            recipe = json.loads(Path(result['workflow']).read_text())
            self.assertEqual([node['type'] for node in recipe['steps']], ['watch', 'step', 'watch'])
            self.assertEqual(recipe['steps'][0]['config']['request_digest'], receipt.check(phase, self.request_path)['request_digest'])
            self.assertIn('--terminal', recipe['steps'][2]['config']['command'])
            config = recipe['steps'][0]['config']
            output = json.loads(subprocess.check_output(shlex.split(config['command']),
                input=json.dumps({'cursor': None, 'config': config, 'workspacePath': str(workspace), 'additionalDirectories': []}), text=True))
            self.assertIsInstance(output['payload'], str)
            self.assertEqual(json.loads(output['payload'])['request_digest'], config['request_digest'])
            self.assertEqual(recipe['steps'][1]['modelId'], 'fixture-model')
            self.assertEqual(recipe['steps'][1]['agent'], materialize.agent_name(phase, profile))
            self.assertIn(str(self.request_path), recipe['steps'][1]['prompt'])
            self.assertFalse((workspace / '.kiro' / 'agents').exists())
            with self.assertRaises(FileExistsError):
                materialize.materialize(phase, profile_path, self.request_path, workspace)


if __name__ == '__main__':
    unittest.main()
