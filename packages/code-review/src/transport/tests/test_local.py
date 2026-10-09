"""Synthetic local Git/observations only; never invoke glab/MCP or inference."""
import argparse
import copy
import datetime
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path


HERE = Path(os.environ.get('CODE_REVIEW_TRANSPORT', Path(__file__).resolve().parents[1]))
spec = importlib.util.spec_from_file_location('transport_local', HERE / 'local.py')
local = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local)


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.checkout = self.root / 'source'
        self.checkout.mkdir()
        self.git('init', '-q')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.git('config', 'user.name', 'Fixture')
        (self.checkout / 'main.py').write_text('x = 1\n')
        self.git('add', 'main.py')
        self.git('-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'base')
        base = self.git('rev-parse', 'HEAD').strip()
        (self.checkout / 'main.py').write_text('x = 2\n')
        self.git('add', 'main.py')
        self.git('-c', 'core.hooksPath=/dev/null', 'commit', '-qm', 'head')
        head = self.git('rev-parse', 'HEAD').strip()
        self.refs = {'base_sha': base, 'head_sha': head, 'start_sha': base}
        self.value = {'schema_version': 1, 'complete': True, 'observed_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                      'target': {'host': 'gitlab.example.invalid', 'project_id': '12', 'mr_iid': '3', **self.refs},
                      'before_refs': self.refs, 'after_refs': self.refs, 'discussions': []}
        self.snapshot_path = self.root / 'remote.json'
        self.store_snapshot()
        self.report_path = self.root / 'report.json'
        self.md = self.root / 'report.md'
        self.report = {'schema_version': 1, 'status': {'complete': True},
                       'target': {'id': local.target_id(self.value['target']), 'base_sha': base, 'head_sha': head},
                       'provenance': {'input_digest': 'a' * 64}, 'findings': []}
        local.write(self.report_path, self.report)
        self.md.write_bytes(b'# Complete report\r\n\r\nNo accepted findings.\r\n')
        self.pub = self.root / 'publication'

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.checkout), *args], text=True, stderr=subprocess.PIPE)

    def store_snapshot(self):
        local.write(self.snapshot_path, self.value)

    def plan(self, action='create', **overrides):
        fields = dict(snapshot=str(self.snapshot_path), report_json=str(self.report_path), report_md=str(self.md),
                      publication_dir=str(self.pub), action=action, discussion_id=None, note_id=None,
                      baseline_hash=None, owner_id=None)
        fields.update(overrides)
        return local.plan(argparse.Namespace(**fields))

    def observe(self):
        self.store_snapshot()
        return local.observe(argparse.Namespace(publication_dir=str(self.pub), snapshot=str(self.snapshot_path)))

    def begin(self):
        return local.begin(argparse.Namespace(publication_dir=str(self.pub)))

    def note(self, body, author='publisher', note_id='9'):
        return {'id': 'thread', 'resolved': False, 'notes': [{'id': note_id, 'body': body,
                'updated_at': '2026-10-08T20:00:00Z', 'author': {'id': author, 'username': 'Identity'}}]}

    def test_freeze_pins_input_and_removes_author_fields(self):
        self.value['discussions'] = [self.note('identity may remain in body')]
        self.store_snapshot()
        destination = self.root / 'frozen'
        args = argparse.Namespace(snapshot=str(self.snapshot_path), checkout=str(self.checkout),
                                  output_dir=str(destination), house_rules=None, intake=None)
        result = local.freeze(args)
        self.assertTrue(result['ready'])
        bundle = local.read(result['bundle'])
        self.assertEqual(bundle['target']['id'], 'gitlab:gitlab.example.invalid:12!3')
        self.assertNotIn('author', bundle['comments'][0]['notes'][0])
        self.assertIn('author', local.read(result['snapshot'])['discussions'][0]['notes'][0])
        self.assertIn('+x = 2', Path(bundle['diff']).read_text())
        self.assertEqual(local.verify_freeze(argparse.Namespace(frozen_dir=str(destination))), result)
        with self.assertRaisesRegex(ValueError, 'overwrite'):
            local.freeze(args)
        Path(bundle['diff']).write_text('tampered')
        with self.assertRaisesRegex(ValueError, 'diff changed'):
            local.verify_freeze(argparse.Namespace(frozen_dir=str(destination)))

    def test_freeze_refuses_dirty_source_and_source_output(self):
        args = argparse.Namespace(snapshot=str(self.snapshot_path), checkout=str(self.checkout),
                                  output_dir=str(self.root / 'frozen'), house_rules=None, intake=None)
        (self.checkout / 'untracked.txt').write_text('dirty')
        with self.assertRaisesRegex(ValueError, 'clean'):
            local.freeze(args)
        args.output_dir = str(self.checkout / 'output')
        with self.assertRaisesRegex(ValueError, 'outside checkout'):
            local.freeze(args)

    def test_frozen_bundle_is_consumed_by_shared_prepare_and_intake(self):
        intake = self.root / 'claims.json'
        local.write(intake, {'claims': [{'claim': 'Synthetic candidate', 'locus': {'file': 'main.py', 'line': 1}}]})
        receipt = local.freeze(argparse.Namespace(snapshot=str(self.snapshot_path), checkout=str(self.checkout),
                               output_dir=str(self.root / 'frozen'), house_rules=None, intake=str(intake)))
        helper = HERE.parent / 'shared' / 'review.py'
        run = self.root / 'arm-run'
        prepared = subprocess.run(['python3', str(helper), 'prepare', '--input', receipt['bundle'],
                                   '--run-dir', str(run), '--arm', 'fixture', '--runtime', 'kimchi', '--pass', '1'],
                                  text=True, capture_output=True)
        self.assertEqual(prepared.returncode, 0, prepared.stdout + prepared.stderr)
        admitted = subprocess.run(['python3', str(helper), 'intake', '--input', receipt['intake'], '--run-dir', str(run), '--arm', 'fixture'],
                                 text=True, capture_output=True)
        self.assertEqual(admitted.returncode, 0, admitted.stdout + admitted.stderr)
        self.assertEqual(len(local.read(run / 'state.json')['pending_intake']), 1)

    def test_snapshot_refuses_partial_drift_duplicate_and_credential_host(self):
        for modification, message in (({'complete': False}, 'complete'),
                                      ({'after_refs': {**self.refs, 'head_sha': 'a' * 40}}, 'refs changed'),
                                      ({'discussions': [self.note('one'), self.note('two')]}, 'duplicate discussion')):
            original = copy.deepcopy(self.value)
            self.value.update(modification)
            self.store_snapshot()
            with self.assertRaisesRegex(ValueError, message):
                local.snapshot(self.snapshot_path)
            self.value = original
        self.value['target']['host'] = 'token@gitlab.example.invalid'
        self.store_snapshot()
        with self.assertRaisesRegex(ValueError, 'hostname'):
            local.snapshot(self.snapshot_path)

    def test_plan_preserves_report_and_rejects_wrong_target_incomplete_and_overwrite(self):
        self.report['status']['complete'] = False
        local.write(self.report_path, self.report)
        with self.assertRaisesRegex(ValueError, 'complete'):
            self.plan()
        self.report['status']['complete'] = True
        self.report['target']['id'] = 'other'
        local.write(self.report_path, self.report)
        with self.assertRaisesRegex(ValueError, 'target differs'):
            self.plan()
        self.report['target']['id'] = local.target_id(self.value['target'])
        local.write(self.report_path, self.report)
        result = self.plan()
        plan = local.read(result['plan'])
        self.assertTrue(plan['body'].startswith(self.md.read_bytes().decode()))
        with self.assertRaisesRegex(ValueError, 'overwrite'):
            self.plan()

    def test_intent_is_durable_missing_observation_uncertain_and_never_retried(self):
        self.plan()
        with self.assertRaisesRegex(ValueError, 'fresh observation'):
            self.begin()
        self.assertEqual(self.observe()['state'], 'ready')
        request = self.begin()
        self.assertEqual(local.read(self.pub / 'ledger.json')['state'], 'started')
        self.assertEqual(request['method'], 'POST')
        self.assertEqual(self.observe()['state'], 'uncertain')
        with self.assertRaisesRegex(ValueError, 'cannot retry'):
            self.begin()
        plan = local.read(self.pub / 'plan.json')
        self.value['discussions'] = [self.note(plan['body'])]
        self.assertEqual(self.observe()['state'], 'verified')
        with self.assertRaisesRegex(ValueError, 'cannot retry'):
            self.begin()

    def test_plan_hashes_the_same_bytes_it_validates_and_renders(self):
        original = Path.read_bytes
        reads = {self.report_path: 0, self.md: 0}
        def counted(path):
            if path in reads:
                reads[path] += 1
                self.assertEqual(reads[path], 1, 'report was reread during sealing')
            return original(path)
        with patch.object(Path, 'read_bytes', counted):
            self.plan()
        sealed = local.read(self.pub / 'plan.json')
        self.assertEqual(sealed['report_json_sha256'], local.sha(original(self.report_path)))
        self.assertEqual(sealed['report_md_sha256'], local.sha(original(self.md)))
        self.assertTrue(sealed['body'].startswith(original(self.md).decode('utf-8')))

    def test_exact_adoption_duplicate_marker_conflict_and_head_drift(self):
        self.plan()
        plan = local.read(self.pub / 'plan.json')
        self.value['discussions'] = [self.note(plan['body'])]
        self.assertEqual(self.observe()['receipt']['note_id'], '9')
        self.value['discussions'].append({**self.note(plan['body'], note_id='10'), 'id': 'other'})
        with self.assertRaisesRegex(ValueError, 'duplicate operation'):
            self.observe()
        self.assertEqual(local.read(self.pub / 'ledger.json')['state'], 'blocked')
        self.value['discussions'] = [self.note('edited ' + plan['body'])]
        with self.assertRaisesRegex(ValueError, 'conflicting body'):
            self.observe()
        self.value['target'] = {**self.value['target'], 'head_sha': 'e' * 40}
        self.value['before_refs'] = self.value['after_refs'] = {**self.refs, 'head_sha': 'e' * 40}
        with self.assertRaisesRegex(ValueError, 'target/refs changed'):
            self.observe()

    def test_update_ownership_author_edit_and_exact_target_guards(self):
        old = 'old report\n<!-- review-ab:report=' + 'a' * 64 + ' -->\n'
        self.value['discussions'] = [self.note(old)]
        self.store_snapshot()
        arguments = dict(discussion_id='thread', note_id='9', baseline_hash=local.sha(old), owner_id='foreign')
        with self.assertRaisesRegex(ValueError, 'own note author'):
            self.plan('update', **arguments)
        arguments['owner_id'] = 'publisher'
        self.plan('update', **arguments)
        self.value['discussions'] = [self.note(old + 'author edit')]
        with self.assertRaisesRegex(ValueError, 'preserve author edits'):
            self.observe()
        with self.assertRaisesRegex(ValueError, 'fresh observation'):
            self.begin()
        plan = local.read(self.pub / 'plan.json')
        self.value['discussions'] = [self.note(plan['body'], note_id='10')]
        with self.assertRaisesRegex(ValueError, 'wrong note'):
            self.observe()

    def test_sealed_plan_and_request_tampering_refuse(self):
        self.plan()
        local.write(self.pub / 'request.json', {'body': 'changed'})
        with self.assertRaisesRegex(ValueError, 'request changed'):
            self.begin()
        plan = local.read(self.pub / 'plan.json')
        local.write(self.pub / 'request.json', {'body': plan['body']})
        plan['endpoint'] = 'other'
        local.write(self.pub / 'plan.json', plan)
        with self.assertRaisesRegex(ValueError, 'plan changed'):
            self.observe()

    def test_bad_fresh_observation_invalidates_ready_control(self):
        self.plan()
        for bad in ('malformed', 'refs', 'timestamp'):
            self.value['after_refs'] = self.refs
            self.value['observed_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
            self.observe()
            if bad == 'malformed':
                self.snapshot_path.write_text('{broken')
            elif bad == 'refs':
                self.value['after_refs'] = {**self.refs, 'head_sha': 'a' * 40}
                self.store_snapshot()
            else:
                self.value['observed_at'] = 'not-a-timestamp'
                self.store_snapshot()
            with self.assertRaises(ValueError):
                local.observe(argparse.Namespace(publication_dir=str(self.pub), snapshot=str(self.snapshot_path)))
            self.assertEqual(local.read(self.pub / 'ledger.json')['state'], 'blocked')
            with self.assertRaisesRegex(ValueError, 'fresh observation'):
                self.begin()

    def test_stale_observation_and_expired_preflight_refuse(self):
        self.plan()
        now = datetime.datetime.now(datetime.timezone.utc)
        self.value['observed_at'] = (now - datetime.timedelta(minutes=6)).isoformat()
        with self.assertRaisesRegex(ValueError, 'stale'):
            self.observe()
        self.value['observed_at'] = now.isoformat()
        self.observe()
        ledger = local.read(self.pub / 'ledger.json')
        ledger['preflight']['observed_at'] = (now - datetime.timedelta(minutes=6)).isoformat()
        local.write(self.pub / 'ledger.json', ledger)
        with self.assertRaisesRegex(ValueError, 'stale'):
            self.begin()
        self.assertFalse(local.read(self.pub / 'ledger.json')['ever_started'])


if __name__ == '__main__':
    unittest.main()
