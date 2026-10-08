"""Exercise the Kimchi launchers' trust notice against the native user trust/default files."""

import itertools
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary)
    root = base / "parent/project"
    root.mkdir(parents=True)
    user_home = base / "home"

    def write_trust(entries):
        trust.write_text(json.dumps({str(path): value for path, value in entries}))

    # Arguments pair each launcher with its user harness, relative to HOME.
    pairs = list(zip(sys.argv[1::2], sys.argv[2::2]))
    for (launcher, relative), target in itertools.product(pairs, (".kimchi/config.json", ".config/kimchi/harness/settings.json")):
        harness = user_home / relative
        harness.mkdir(parents=True, exist_ok=True)
        trust, settings = harness / "trust.json", harness / "settings.json"
        project_file = root / target
        project_file.parent.mkdir(parents=True, exist_ok=True)
        project_file.write_text('{"defaultProjectTrust": "always"}')

        def probe(warning, directory=root):
            env = dict(os.environ, HOME=str(user_home))
            result = subprocess.run([launcher], cwd=directory, env=env, capture_output=True, text=True, check=True)
            assert result.stdout == "", result
            if warning:
                assert "warning: Kimchi project files" in result.stderr
                assert str(root) in result.stderr and str(trust) in result.stderr
            else:
                assert result.stderr == "", result.stderr

        settings.write_text('{"defaultProjectTrust": "never"}')
        write_trust([])
        probe(True)  # project config cannot trust itself
        write_trust([(root, True)])
        probe(False)
        write_trust([(root.parent, True)])
        probe(False)
        write_trust([(root.parent, True), (root, False)])
        probe(True)
        settings.write_text('{"defaultProjectTrust": "always"}')
        probe(True)  # nearest denial still wins
        write_trust([(root.parent, False), (root, True)])
        probe(False)
        write_trust([])
        probe(False)  # global always, with no persisted decision
        for default in ("ask", "never", None):
            settings.write_text(json.dumps({} if default is None else {"defaultProjectTrust": default}))
            probe(True)
        write_trust([(root.parent, True), (root, None)])
        probe(False)  # null entries inherit the nearest parent's decision
        alias = base / "alias"
        if not alias.exists():
            alias.symlink_to(root, target_is_directory=True)
        probe(False, alias)
        # Every absence/unreadability probe has a warning-producing control.
        for path in (trust, settings, project_file):
            write_trust([])
            settings.write_text('{"defaultProjectTrust": "never"}')
            probe(True)
            contents = path.read_text()
            path.unlink()
            probe(False)
            path.write_text(contents)
            probe(True)
            path.chmod(0)
            try:
                probe(False)
            finally:
                path.chmod(0o600)
        for malformed in ("not JSON", "[]", '{"bad": 1}'):
            write_trust([])
            probe(True)
            trust.write_text(malformed)
            probe(False)
        # From $HOME the project harness path is the user harness itself,
        # unless configDir moved the user harness elsewhere.
        write_trust([])
        probe(True)
        if relative == ".config/kimchi/harness":
            probe(False, user_home)
        project_file.unlink()
