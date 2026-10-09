"""Offline contract tests with fake role outputs; no model or service access."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('review', Path(os.environ.get('CODE_REVIEW_SHARED', Path(__file__).parents[1])) / 'review.py')
core = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(core)
BANKS = ['correctness-security', 'docs', 'house', 'maintainability-reuse', 'testing']
LENS = {'name': 'maintainer', 'questions': ['What breaks?'], 'ecosystem': 'generic', 'corpus': 'maintainers',
        'confidence': 'low', 'basis': [], 'banks': BANKS}


class ReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.checkout = self.root / 'checkout'
        self.checkout.mkdir()
        for args in [('init', '-q'), ('config', 'user.email', 'fixture@example.com'), ('config', 'user.name', 'Fixture')]:
            subprocess.run(['git', '-C', str(self.checkout), *args], check=True)
        (self.checkout / 'a.py').write_text('value = 2\n')
        subprocess.run(['git', '-C', str(self.checkout), 'add', 'a.py'], check=True)
        subprocess.run(['git', '-C', str(self.checkout), 'commit', '-qm', 'fixture'], check=True)
        self.head = core.git(self.checkout, 'rev-parse', 'HEAD')
        self.diff = self.root / 'diff'
        self.diff.write_text('diff --git a/a.py b/a.py\n--- a/a.py\n+++ b/a.py\n@@ -1 +1 @@\n-value = 1\n+value = 2\n')
        self.bundle = self.root / 'bundle.json'
        core.atomic(self.bundle, {'schema_version': 1, 'target': {'id': 'fixture', 'base_sha': self.head, 'head_sha': self.head},
                                 'checkout': str(self.checkout), 'diff': str(self.diff), 'house_rules': ['Keep it simple.']})
        self.run = self.root / 'run'
        self.prepare_args = argparse.Namespace(command='prepare', input=str(self.bundle), run_dir=str(self.run), arm='kimchi-frontier',
                                               runtime='kimchi', profile=None, review_pass=1, chunk_lines=2, chunk_chars=1000, max_waves=3)
        core.prepare(self.prepare_args)
        self.state = core.read(self.run / 'state.json')

    def test_submitted_output_budget_combines_parse_schema_and_relation(self):
        task = self.phase('lens')[0]
        first = core.submit_attempt(self.state, self.run, task, None, parse_error='invalid JSON')
        self.assertFalse(first['accepted'])
        second = core.submit_attempt(self.state, self.run, task, None, {})
        self.assertFalse(second['accepted'])
        third = core.submit_attempt(self.state, self.run, task, None, {'task_id': 'wrong', 'lenses': [LENS]})
        self.assertTrue(third['exhausted'])
        core.atomic(self.run / 'state.json', self.state)
        recovered = core.read(self.run / 'state.json')
        fourth = core.submit_attempt(recovered, self.run, recovered['tasks'][task['id']], None, {'task_id': task['id'], 'lenses': [LENS]})
        self.assertFalse(fourth['accepted'])
        self.assertEqual(fourth['attempt'], 3)
        self.assertFalse(recovered['tasks'][task['id']]['complete'])
        self.assertEqual(len(task['submission_attempts']['lens']), 3)

    def test_rejected_proposal_replay_is_durable_but_new_same_content_counts(self):
        task = self.phase('lens')[0]
        first = core.submit_attempt(self.state, self.run, task, None, {}, proposal_id='first')
        core.atomic(self.run / 'state.json', self.state)
        recovered = core.read(self.run / 'state.json')
        current = recovered['tasks'][task['id']]
        self.assertEqual(core.submit_attempt(recovered, self.run, current, None, {}, proposal_id='first'), first)
        self.assertEqual(len(current['submission_attempts']['lens']), 1)
        with self.assertRaisesRegex(core.ContractError, 'replay changed'):
            core.submit_attempt(recovered, self.run, current, None, {'changed': True}, proposal_id='first')
        second = core.submit_attempt(recovered, self.run, current, None, {}, proposal_id='second')
        self.assertEqual(second['attempt'], 2)

    def test_third_submission_can_succeed_and_provenance_is_not_telemetry(self):
        task = self.phase('lens')[0]
        for result in ({}, {'task_id': 'wrong', 'lenses': [LENS]}):
            core.submit_attempt(self.state, self.run, task, None, result)
        good = {'task_id': task['id'], 'lenses': [LENS]}
        receipt = core.submit_attempt(self.state, self.run, task, None, good)
        self.assertTrue(receipt['accepted'])
        self.assertEqual(receipt['attempt'], 3)
        self.assertTrue(core.submit_attempt(self.state, self.run, task, None, good)['accepted'])
        self.assertEqual(len(task['submission_attempts']['lens']), 3)
        controls = core.native_controls(self.state)
        self.assertIn('unknown', controls['provider_effective_settings'])
        self.assertEqual(controls['submission_policy']['corrections'], 2)

    def test_cli_invalid_json_receipt_replay_preserves_budget(self):
        task = self.phase('lens')[0]
        core.atomic(self.run / 'state.json', self.state)
        result = self.root / 'immutable-proposal.json'
        result.write_text('{not json')
        command = ['python3', str(core.ROOT / 'review.py'), 'submit', '--run-dir', str(self.run),
                   '--arm', self.state['arm'], '--task', task['id'], '--proposal-id', 'proposal-one', '--result', str(result)]
        first = subprocess.run(command, capture_output=True, text=True, check=True)
        replay = subprocess.run(command, capture_output=True, text=True, check=True)
        self.assertEqual(json.loads(first.stdout), json.loads(replay.stdout))
        self.assertIn('invalid JSON', json.loads(first.stdout)['error'])
        self.assertEqual(len(core.read(self.run / 'state.json')['tasks'][task['id']]['submission_attempts']['lens']), 1)

    def test_helper_claim_overhead_is_counted_without_model_telemetry(self):
        self.state['runtime'] = 'kiro-cli'
        task = self.phase('lens')[0]
        core.atomic(self.run / 'state.json', self.state)
        args = argparse.Namespace(command='claim', run_dir=str(self.run), arm=self.state['arm'],
                                  stage='lens', worker='lens-0', control_only=True)
        core.execute(args)
        state = core.read(self.run / 'state.json')
        core.submit(state, self.run, state['tasks'][task['id']], None, {'task_id': task['id'], 'lenses': [LENS]})
        core.atomic(self.run / 'state.json', state)
        core.execute(args)
        overhead = core.native_controls(core.read(self.run / 'state.json'))['overhead']
        self.assertEqual(overhead['helper_claim_observations']['claim_commands'], 2)
        self.assertEqual(overhead['helper_claim_observations']['empty_claim_commands'], 1)
        self.assertIsNone(overhead['actual_model_requests'])
        self.assertIsNone(overhead['tokens'])

    def cand(self, claim='changed value may be wrong'):
        return {'claim': claim, 'locus': {'file': 'a.py', 'side': 'new', 'line': 1}, 'citations': []}

    def result(self, task, role, **fields):
        return core.submit(self.state, self.run, task, role, {'task_id': task['id'], **fields})

    def phase(self, stage):
        core.init_stage(self.state, stage)
        return core.stage_tasks(self.state, stage)

    def through_adjudication(self, severity='low', discovery=None, candidate_override=None):
        for task in self.phase('lens'):
            self.result(task, 'lens', lenses=[LENS])
        task = self.phase('refine')[0]
        self.result(task, 'refine', lenses=[{**LENS, 'id': 'maintainer', 'chunk_ids': [c['id'] for c in self.state['chunks']]}])
        for task in self.phase('surface'):
            intake = [i for i in task['input']['intake'] if 'candidate' in i]
            candidates = [{**i['candidate'], 'intake_id': i['id']} for i in intake] or [candidate_override or self.cand()]
            self.result(task, 'surface', candidates=candidates)
        task = self.phase('dedupe')[0]
        # One exact claim may surface from multiple bounded chunks: merge explicitly.
        self.result(task, 'dedupe', groups=[[c['id'] for c in task['input']['candidates']]])
        claims = self.phase('adjudicate')
        for task in claims:
            citation = {'file': 'a.py', 'line': 1, 'supports': 'Changed value is 2.'}
            self.result(task, 'evidence', citations=[citation], verify_path='Read a.py:1.', needs_defense=False)
            self.result(task, 'judge', disposition='accepted', severity=severity, reason='Concrete consequence.', citations=[citation],
                        verify_path='Read a.py:1.', discoveries=[discovery] if discovery else [])
        return claims

    def finalize(self, decision=None):
        task = self.phase('finalize')[0]
        entries = task['input']['claims']
        self.result(task, 'finalize', decisions=[{'id': c['id'], 'disposition': decision or c['judgment']['disposition'],
                                                'severity': c['judgment']['severity'], 'reason': 'Holistically checked.'} for c in entries])

    def test_escaping_paths_and_citation_bounds(self):
        for path in ('../escape', '/absolute'):
            with self.assertRaises(core.ContractError):
                core.safe_file(self.checkout, path)
        (self.checkout / 'escape').symlink_to(self.root / 'diff')
        with self.assertRaises(core.ContractError):
            core.safe_file(self.checkout, 'escape')
        with self.assertRaises(core.ContractError):
            core.location(self.checkout, {'file': 'a.py', 'line': 2, 'supports': 'x'}, True)

    def test_dirty_checkout_and_drift_refuse(self):
        (self.checkout / 'a.py').write_text('changed\n')
        with self.assertRaises(core.ContractError):
            core.prepare(self.prepare_args)
        task = self.phase('lens')[0]
        with self.assertRaises(core.ContractError):
            core.payload(self.state, task)

    def test_same_arm_and_profile_history(self):
        prior = self.root / 'prior.json'
        core.atomic(prior, {'arm': 'kimchi-open', 'target': {'id': 'fixture'}, 'provenance': {'profile_digest': core.digest({})}})
        data = core.read(self.bundle)
        data['prior_report'] = str(prior)
        core.atomic(self.bundle, data)
        with self.assertRaises(core.ContractError):
            core.prepare(self.prepare_args)
        data = core.read(prior)
        data['arm'] = self.prepare_args.arm
        data['provenance']['profile_digest'] = 'wrong'
        core.atomic(prior, data)
        with self.assertRaises(core.ContractError):
            core.prepare(self.prepare_args)

    def test_missing_receipts_do_not_advance(self):
        self.phase('lens')
        with self.assertRaises(core.ContractError):
            self.phase('refine')
        result = core.report(self.state, self.run)
        self.assertFalse(result['status']['complete'])
        self.assertIn('Missing worker receipt', (self.run / 'report.md').read_text())

    def test_distinct_claims_same_locus_are_only_pair_proposals(self):
        a, b = self.cand('SQL injection'), self.cand('uninformative variable')
        a['id'], b['id'] = 'a', 'b'
        self.assertEqual(core.pair_proposals([a, b])[0]['geometry'], True)
        self.assertNotEqual(core.claim_key(a), core.claim_key(b))

    def test_pass_policy_preserves_every_disposition(self):
        self.through_adjudication()
        self.finalize()
        for review_pass, accepted in ((1, 1), (2, 0), (3, 0)):
            self.state['pass'] = review_pass
            core.report(self.state, self.run)
            report = core.read(self.run / 'report.json')
            self.assertEqual(report['summary']['accepted'], accepted)
            self.assertEqual(len(report['outcomes']), 1)
        self.assertIn('judge', (self.run / 'journal.jsonl').read_text())

    def test_defense_independent_and_judge_receipts_required(self):
        self.through_adjudication()
        task = core.stage_tasks(self.state, 'adjudicate')[0]
        task['results'] = {}
        task['complete'] = False
        citation = {'file': 'a.py', 'line': 1, 'supports': 'x'}
        self.result(task, 'evidence', citations=[citation], verify_path='check', needs_defense=True, narrative='secret producer argument')
        with self.assertRaises(core.ContractError):
            core.payload(self.state, task, 'judge')
        defense = core.payload(self.state, task, 'defense')
        self.assertNotIn('prosecution', defense['input'])
        self.assertNotIn('secret producer argument', core.canonical(defense))
        self.result(task, 'defense', citations=[], reason='No counter-evidence.')
        judge = core.payload(self.state, task, 'judge')
        self.assertNotIn('secret producer argument', core.canonical(judge))
        self.assertEqual(judge['input']['task_id'], task['id'])

    def test_replay_conflicts_and_intake_idempotency(self):
        task = self.phase('lens')[0]
        output = {'task_id': task['id'], 'lenses': [LENS]}
        core.submit(self.state, self.run, task, 'lens', output)
        core.submit(self.state, self.run, task, 'lens', output)
        with self.assertRaises(core.ContractError):
            core.submit(self.state, self.run, task, 'lens', {**output, 'narrative': 'conflicting'})
        request = {'claims': [self.cand()], 'steering': 'Inspect cleanup.'}
        self.assertTrue(core.intake(self.state, self.run, request))
        self.assertFalse(core.intake(self.state, self.run, request))
        self.assertEqual(len(self.state['pending_intake']), 2)

    def test_discoveries_reenter_entire_loop_and_budget_is_incomplete(self):
        self.through_adjudication(discovery=self.cand('new issue'))
        self.finalize()
        self.assertFalse(core.status(self.state)['complete'])
        self.assertTrue(core.advance(self.state)['continue'])
        self.assertEqual(self.state['stages'], {})
        self.assertTrue(self.phase('lens')[0]['input']['intake'])
        with self.assertRaises(core.ContractError):
            self.phase('adjudicate')

    def test_metadata_coverage_and_giant_line_diagnostic(self):
        metadata = 'diff --git a/a.py b/a.py\nold mode 100644\nnew mode 100755\n'
        chunks, loci = core.chunks_from_diff(self.checkout, self.diff.read_text()+metadata, 2, 10)
        self.assertTrue(any(c.get('metadata_change') for c in chunks))
        self.assertTrue(any(c.get('context_issue') for c in chunks))
        self.assertTrue(all(len(c['diff']) <= 10 for c in chunks))
        self.assertEqual(len(loci), 2)

    def test_earlier_wave_exact_identity_replaces_and_finalizer_can_contract(self):
        self.through_adjudication(discovery=self.cand())
        self.finalize()
        core.advance(self.state)
        self.through_adjudication()
        task = self.phase('finalize')[0]
        self.assertEqual(len(task['input']['claims']), 1)
        self.finalize('rejected')
        self.assertEqual(len(self.state['outcomes']), 1)
        self.assertEqual(self.state['outcomes'][0]['disposition'], 'rejected')

    def test_prepare_replay_controls_runtime_prior_and_checkout(self):
        for field, value in (('chunk_lines', 3), ('runtime', 'kiro-cli'), ('chunk_chars', 2000)):
            original = getattr(self.prepare_args, field)
            setattr(self.prepare_args, field, value)
            with self.assertRaises(core.ContractError):
                core.prepare(self.prepare_args)
            setattr(self.prepare_args, field, original)

    def test_wave_budget_and_context_issues_report_incomplete(self):
        self.state['max_waves'] = 1
        self.through_adjudication(discovery=self.cand('fresh issue'))
        self.finalize()
        self.assertEqual(core.advance(self.state)['incomplete'], True)
        self.assertFalse(core.status(self.state)['complete'])
        core.report(self.state, self.run)
        self.assertIn('Pending full-loop intake', (self.run / 'report.md').read_text())
        self.state['pending_intake'] = []
        self.state['budget_exhausted'] = False
        self.state['context_issues'] = [{'reason': 'unbounded line'}]
        self.assertFalse(core.status(self.state)['complete'])

    def test_all_wave_holistic_set_contracts_earlier_acceptance(self):
        self.through_adjudication(discovery=self.cand('different issue'))
        self.finalize()
        original = self.state['outcomes'][0]['id']
        core.advance(self.state)
        self.through_adjudication()
        task = self.phase('finalize')[0]
        self.assertEqual(len(task['input']['claims']), 2)
        self.result(task, 'finalize', decisions=[{'id': c['id'], 'disposition': 'rejected' if c['id'] == original else 'accepted',
                                                'severity': 'low', 'reason': 'Final contraction.'} for c in task['input']['claims']])
        self.assertEqual(next(o for o in self.state['outcomes'] if o['id'] == original)['disposition'], 'rejected')

    def test_exact_discovery_replay_does_not_chase_wave_cap(self):
        discovery = self.cand('same discovered issue')
        self.through_adjudication(discovery=discovery)
        self.finalize()
        core.advance(self.state)
        self.through_adjudication(discovery=discovery)
        self.finalize()
        self.assertFalse(core.advance(self.state)['continue'])
        self.assertTrue(core.status(self.state)['complete'])
        self.assertIn('exact_discovery_replay', (self.run / 'journal.jsonl').read_text())

    def test_claim_control_only_recovers_only_owed_role(self):
        self.through_adjudication()
        task = core.stage_tasks(self.state, 'adjudicate')[0]
        task['complete'] = False
        task['results'].pop('judge')
        core.atomic(self.run / 'state.json', self.state)
        args = argparse.Namespace(command='claim', run_dir=str(self.run), arm=self.state['arm'], stage='adjudicate', worker='slot1', control_only=True)
        result = core.execute(args)
        self.assertEqual(result['task']['next_role'], 'judge')
        self.assertEqual(result['task']['completed_roles'], ['evidence'])
        self.assertNotIn('claim', result['task'])
        other = argparse.Namespace(**{**vars(args), 'worker': 'slot2'})
        self.assertIsNone(core.execute(other)['task'])
        self.assertFalse(core.execute(other)['drained'])
        core.execute(argparse.Namespace(command='release', run_dir=str(self.run), arm=self.state['arm'], task=task['id'], worker='slot1'))
        self.assertEqual(core.execute(other)['task']['id'], task['id'])

    def test_shared_schema_matches_native_role_shapes(self):
        for value, schema in (({'task_id': 3}, {'type': 'object', 'properties': {'task_id': {'type': 'string'}}}),
                              ({}, {'type': 'object', 'required': ['task_id']}),
                              ([False], {'type': 'array', 'items': {'type': 'integer'}})):
            with self.assertRaises(core.ContractError):
                core.validate_shape(value, schema)
        task = self.phase('lens')[0]
        with self.assertRaises(core.ContractError):
            self.result(task, 'lens', lenses=[{**LENS, 'questions': [3]}])

    def test_mode_metadata_survives_text_hunk(self):
        diff = self.diff.read_text().replace('--- a/a.py', 'old mode 100644\nnew mode 100755\n--- a/a.py')
        chunks, _ = core.chunks_from_diff(self.checkout, diff, 2)
        self.assertTrue(any('new mode 100755' in c['diff'] for c in chunks))

    def test_dedupe_cannot_validity_drop_intake_before_evidence(self):
        self.through_adjudication(discovery=self.cand('new issue'))
        self.finalize()
        core.advance(self.state)
        for task in self.phase('lens'):
            self.result(task, 'lens', lenses=[LENS])
        task = self.phase('refine')[0]
        self.result(task, 'refine', lenses=[{**LENS, 'id': 'maintainer', 'chunk_ids': [c['id'] for c in self.state['chunks']]}])
        for task in self.phase('surface'):
            entry = task['input']['intake'][0]
            self.result(task, 'surface', candidates=[{**entry['candidate'], 'intake_id': entry['id']}])
        task = self.phase('dedupe')[0]
        dropped = [{'id': c['id'], 'reason': 'Looks false'} for c in task['input']['candidates']]
        with self.assertRaises(core.ContractError):
            self.result(task, 'dedupe', groups=[], dropped=dropped)
        self.assertFalse(core.status(self.state)['complete'])

    def test_finalizer_cannot_inflate_low_to_critical(self):
        self.state['pass'] = 3
        self.through_adjudication('low')
        task = self.phase('finalize')[0]
        with self.assertRaises(core.ContractError):
            self.result(task, 'finalize', decisions=[{'id': c['id'], 'disposition': 'accepted', 'severity': 'critical', 'reason': 'Inflated.'} for c in task['input']['claims']])
        self.assertEqual(self.state['outcomes'], [])

    def test_complete_offline_report(self):
        self.through_adjudication('high')
        self.finalize()
        result = core.report(self.state, self.run)
        self.assertTrue(result['status']['complete'])
        report = core.read(self.run / 'report.json')
        self.assertEqual(report['summary']['accepted'], 1)
        self.assertIn('house_rules', self.phase('lens')[0]['input'])
        self.assertEqual(report['role_receipts']['judge'], 1)

    def test_family_presentation_preserves_independent_claims_all_instances_and_evidence(self):
        for task in self.phase('lens'):
            self.result(task, 'lens', lenses=[LENS])
        task = self.phase('refine')[0]
        self.result(task, 'refine', lenses=[{**LENS, 'id': 'maintainer', 'chunk_ids': [c['id'] for c in self.state['chunks']]}])
        candidates = [self.cand('First unvalidated boundary'), self.cand('First unvalidated boundary'),
                      self.cand('Second unvalidated boundary'), self.cand('Unrelated storage issue')]
        candidates[0]['related_loci'] = [{'file': 'a.py', 'line': 1, 'side': 'old'}]
        candidates[0]['transcript'] = 'PRIVATE SURFACE TRANSCRIPT'
        for task in self.phase('surface'):
            self.result(task, 'surface', candidates=candidates)
        dedupe = self.phase('dedupe')[0]
        ids = [c['id'] for c in dedupe['input']['candidates']]
        self.result(dedupe, 'dedupe', groups=[[ids[0]], [ids[2]], [ids[3]]],
                    dropped=[{'id': ids[1], 'duplicate_of': ids[0], 'reason': 'Same claim and locus.'}])
        tasks = self.phase('adjudicate')
        cite = {'file': 'a.py', 'line': 1, 'supports': 'Changed value is 2.'}
        for i, task in enumerate(tasks):
            self.result(task, 'evidence', citations=[cite], verify_path='1. Read a.py:1 — observe value 2; establishes input boundary.',
                        needs_defense=i == 0, narrative='PRIVATE PRODUCER ANALYSIS')
            if i == 0:
                self.result(task, 'defense', citations=[cite], reason='Counterevidence: value is scoped to fixture.')
            self.result(task, 'judge', disposition='accepted', severity='medium', reason='Independent cited consequence.', citations=[cite],
                        verify_path='1. Read pinned a.py:1 — expected value 2; observed value 2.', narrative='PRIVATE JUDGE ANALYSIS')
        final = self.phase('finalize')[0]
        self.result(final, 'finalize', decisions=[{'id': t['id'], 'disposition': 'accepted', 'severity': 'medium', 'reason': 'Retained after holistic check.'} for t in tasks],
                    presentation_groups=[{'title': 'Boundary validation </details> [unsafe](javascript:alert(1))', 'claim_ids': [tasks[0]['id'], tasks[1]['id']]}])
        core.report(self.state, self.run)
        report = core.read(self.run / 'report.json')
        markdown = (self.run / 'report.md').read_text()
        self.assertEqual(report['summary']['accepted'], 3)
        self.assertEqual(len(report['presentation_groups']), 2)
        first = report['outcomes'][0]
        self.assertEqual(len(first['members']), 2)
        self.assertEqual(len(first['instances']), 2)
        self.assertEqual(set(first['instances'][0]['candidate_ids']), {ids[0], ids[1]})
        self.assertEqual(set(first['substantiation']), {'evidence', 'defense', 'judge', 'finalizer'})
        self.assertIn('Counterevidence: value is scoped to fixture', markdown)
        self.assertIn('expected value 2; observed value 2', markdown)
        self.assertTrue(markdown.startswith('> 🤖 **AI-generated code review** — automated review agent.'))
        self.assertEqual(markdown.count('</details>'), 3)
        self.assertIn('&lt;/details&gt;', markdown)
        self.assertNotIn('[unsafe](javascript:', markdown)
        self.assertNotIn('PRIVATE', markdown)
        self.assertNotIn('PRIVATE', (self.run / 'report.json').read_text())
        self.assertIn('Unrelated storage issue', markdown)

    def test_presentation_groups_reject_unknown_and_duplicate_claim_ids(self):
        claims = self.through_adjudication()
        final = self.phase('finalize')[0]
        decisions = [{'id': c['id'], 'disposition': 'accepted', 'severity': 'low', 'reason': 'Retained.'} for c in claims]
        for ids in ([claims[0]['id'], 'unknown'], [claims[0]['id'], claims[0]['id']]):
            with self.assertRaises(core.ContractError):
                self.result(final, 'finalize', decisions=decisions, presentation_groups=[{'title': 'Family', 'claim_ids': ids}])
        with self.assertRaises(core.ContractError):
            self.result(final, 'finalize', decisions=decisions, presentation_groups=[{'title': 'A', 'claim_ids': [claims[0]['id']]}, {'title': 'B', 'claim_ids': [claims[0]['id']]}])

    def test_acceptance_and_report_cannot_publish_without_citations(self):
        claims = self.through_adjudication()
        with self.assertRaises(core.ContractError):
            core.check_result(self.state, claims[0], 'judge', {'task_id': claims[0]['id'], 'disposition': 'accepted', 'severity': 'low',
                              'reason': 'Assertion without evidence.', 'citations': [], 'verify_path': 'Read source.'})
        self.finalize()
        self.state['outcomes'][0]['citations'] = []
        with self.assertRaises(core.ContractError):
            core.report(self.state, self.run)

    def test_peer_reference_is_versioned_and_supplied_to_finalizer(self):
        self.through_adjudication()
        task = self.phase('finalize')[0]
        payload = core.payload(self.state, task)
        self.assertIn('references/peer-communication.md', core.versions())
        self.assertIn('Optimize communication for', payload['prompt'])

    def test_same_claim_next_wave_investigates_all_earlier_instances(self):
        original = {**self.cand(), 'related_loci': [{'file': 'a.py', 'line': 1, 'side': 'old'}]}
        self.through_adjudication(candidate_override=original)
        self.finalize()
        core.intake(self.state, self.run, {'claims': [self.cand()]})
        self.assertTrue(core.advance(self.state)['continue'])
        claims = self.through_adjudication()
        self.assertEqual(len(claims[0]['input']['members']), 2)
        self.assertTrue(any(m.get('related_loci') for m in claims[0]['input']['members']))
        self.finalize()
        core.report(self.state, self.run)
        report = core.read(self.run / 'report.json')
        self.assertEqual(len(report['outcomes']), 1)
        self.assertEqual(len(report['outcomes'][0]['instances']), 2)
        self.assertEqual(len(report['outcomes'][0]['instances'][0]['candidate_ids']), 2)

    def test_prior_finalizer_contractions_remain_effective_ceiling(self):
        self.through_adjudication(severity='high')
        final = self.phase('finalize')[0]
        claims = final['input']['claims']
        self.result(final, 'finalize', decisions=[{'id': c['id'], 'disposition': 'rejected', 'severity': 'low', 'reason': 'Contracted.'} for c in claims])
        self.state['wave'] += 1
        previous = core.final_claims(self.state)[0]
        self.assertEqual(previous['judgment']['disposition'], 'rejected')
        self.assertEqual(previous['substantiation']['judge']['disposition'], 'accepted')
        task = {'id': 'next-finalize', 'input': {}, 'stage': 'finalize'}
        with self.assertRaises(core.ContractError):
            core.check_result(self.state, task, 'finalize', {'task_id': task['id'], 'decisions': [{'id': previous['id'], 'disposition': 'accepted', 'severity': 'low', 'reason': 'No new evidence.'}]})
        self.state['outcomes'][0]['disposition'] = 'accepted'
        with self.assertRaises(core.ContractError):
            core.check_result(self.state, task, 'finalize', {'task_id': task['id'], 'decisions': [{'id': previous['id'], 'disposition': 'accepted', 'severity': 'high', 'reason': 'No new evidence.'}]})

    def test_pass_two_low_claim_is_collapsed_not_prominent_and_preserves_instances(self):
        self.state['pass'] = 2
        self.through_adjudication(severity='low')
        self.finalize()
        core.report(self.state, self.run)
        markdown = (self.run / 'report.md').read_text()
        main, other = markdown.split('<details><summary><b>Other dispositions</b></summary>', 1)
        claim = self.cand()['claim']
        self.assertNotIn(claim, main)
        self.assertIn(claim, other)
        self.assertIn('Replay path', other)
        self.assertIn('a\\.py:1', other)
        report = core.read(self.run / 'report.json')
        self.assertEqual(report['summary']['accepted'], 0)
        self.assertEqual(report['summary']['filtered'], 1)
        self.assertEqual(len(report['outcomes'][0]['instances']), 1)

    def test_physical_instance_dedupe_unions_provenance_not_distinct_outcomes(self):
        citations = [{'file': 'a.py', 'line': 1, 'supports': text} for text in ('Source observation.', 'Second observation.')]
        members = [{'id': 'c1', 'claim': 'Boundary defect', 'locus': {'file': 'a.py', 'line': 1}, 'citations': [citations[0]]},
                   {'id': 'c2', 'claim': 'Boundary defect restated', 'locus': {'file': 'a.py', 'line': 1, 'side': 'new'}, 'citations': [citations[1]]}]
        locations = core.instances({'id': 'claim', 'members': members})
        self.assertEqual(len(locations), 1)
        self.assertEqual(locations[0]['candidate_ids'], ['c1', 'c2'])
        self.assertEqual(locations[0]['claims'], ['Boundary defect', 'Boundary defect restated'])
        self.assertEqual(locations[0]['citations'], citations)
        self.assertEqual(len(core.instances({'id': 'separate-claim', 'members': [members[1]]})), 1)


if __name__ == '__main__':
    unittest.main()
