"""Force rendered install resources and bind an overridden profile to native pins."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

payload = Path(os.environ['CODE_REVIEW_PAYLOAD'])
expected = json.loads(Path(os.environ['CODE_REVIEW_AGENTS']).read_text())
for skill_dir in json.loads(os.environ['CODE_REVIEW_SKILLS']):
    skill = (Path(skill_dir) / 'SKILL.md').read_text()
    assert not re.search(r'@[a-z][a-z-]*@', skill), skill
    assert '/home/' not in skill
    profile_path = re.search(r'Profile:\s*`([^`]+)`', skill).group(1)
    assert profile_path.startswith('/nix/store/'), profile_path
    profile = json.loads(Path(profile_path).read_text())
    assert profile['limits'] == {'concurrency': 1, 'max_waves': 2}
    with tempfile.TemporaryDirectory() as directory:
        workspace = Path(directory)
        run = workspace / 'review-state'
        run.mkdir()
        (run / 'state.json').write_text(json.dumps({
            'arm': 'fixture', 'runtime': 'kiro-cli', 'profile': profile,
            'max_waves': 2, 'provenance': {'profile_digest': 'fixture'},
        }))
        result = json.loads(subprocess.check_output([
            sys.executable, str(payload / 'kiro/generate.py'), '--workspace',
            str(workspace), '--run-dir', str(run), '--arm', 'fixture',
            '--profile', profile_path,
        ], env={'PATH': '/nonexistent'}))
        recipe = json.loads(Path(result['workflow']).read_text())
        assert recipe['steps'][0]['maxIterations'] == 2
        pools = [node for node in recipe['steps'][0]['steps'] if node['type'] == 'parallel']
        assert all(len(node['branches']) == 1 for node in pools)
        for pool in pools:
            step = pool['branches'][0]['steps'][0]
            assert step['agent'] in expected, step['agent']
            assert step['modelId'] == expected[step['agent']]['model']
            if 'effortLevel' in step:
                assert step['effortLevel'] == expected[step['agent']]['effortLevel']
        judge = next(record for name, record in expected.items() if name.endswith('-judge'))
        assert judge == {'model': 'fixture-judge', 'effortLevel': 'low'}
print('PASS installed HM/devenv skills, immutable custom profile, native graph pins and limits')
