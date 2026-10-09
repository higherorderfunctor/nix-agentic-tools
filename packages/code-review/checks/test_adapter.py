"""Installed native adapter contracts without model or service requests."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

ROOT = Path(os.environ['CODE_REVIEW_PAYLOAD'])
SPEC = importlib.util.spec_from_file_location('generate', ROOT / 'kiro/generate.py')
generate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(generate)
PROFILE = json.loads((ROOT / 'profiles/kiro.json').read_text())


class InstalledAdapterTests(unittest.TestCase):
    def test_runs_use_installed_agents_and_independent_native_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            recipes = []
            for run in [workspace / 'first', workspace / 'second']:
                run.mkdir()
                (run / 'state.json').write_text(json.dumps({
                    'arm': 'fixture', 'runtime': 'kiro-cli', 'profile': PROFILE,
                    'max_waves': 3, 'provenance': {'profile_digest': 'fixture'},
                }))
                recipe = json.loads(generate.materialize(workspace, run, 'fixture', PROFILE).read_text())
                recipes.append(recipe)
                self.assertEqual(recipe['steps'][0]['maxIterations'], 3)
                self.assertEqual(recipe['steps'][0]['stopCondition']['fileCheck']['path'], f'{run.name}/kiro-next-wave.json')
                pools = [node for node in recipe['steps'][0]['steps'] if node['type'] == 'parallel']
                self.assertEqual([len(node['branches']) for node in pools], [6, 6, 6])
                for node in pools:
                    step = node['branches'][0]['steps'][0]
                    self.assertIn(str(run), step['prompt'])
                    self.assertIn('ARM: fixture', step['prompt'])
                    self.assertNotIn('--run-dir RUN_DIR', step['prompt'])
            self.assertFalse((workspace / '.kiro/agents').exists())
            self.assertNotEqual(recipes[0]['name'], recipes[1]['name'])
            first_agent = recipes[0]['steps'][0]['steps'][1]['branches'][0]['steps'][0]['agent']
            second_agent = recipes[1]['steps'][0]['steps'][1]['branches'][0]['steps'][0]['agent']
            self.assertEqual(first_agent, second_agent)
            identity = hashlib.sha256(json.dumps(PROFILE, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest()[:10]
            self.assertEqual(first_agent, f'code-review-{identity}-lens')

    def test_native_workspace_guard_names_outside_input(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            with self.assertRaisesRegex(ValueError, 'inside workspace'):
                generate.materialize(workspace, workspace.parent / 'outside', 'fixture', PROFILE)


if __name__ == '__main__':
    unittest.main()
