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

        def probe(label, warning, directory=root):
            env = dict(os.environ, HOME=str(user_home))
            result = subprocess.run([launcher], cwd=directory, env=env, capture_output=True, text=True, check=False)
            context = (launcher, target, label, result)
            assert result.returncode == 0 and result.stdout == "", context
            if warning:
                assert "warning: Kimchi project files" in result.stderr, context
                assert str(directory) in result.stderr and str(trust) in result.stderr, context
            else:
                assert result.stderr == "", context

        def set_policy(default, entries=()):
            settings.write_text(json.dumps({} if default is None else {"defaultProjectTrust": default}))
            write_trust(entries)

        for label, default, entries, warns in (
            ("ask is not implicit trust", "ask", (), True),
            ("direct denial overrides both parent approval and global always", "always", ((root.parent, True), (root, False)), True),
            ("global always suppresses the warning without a saved decision", "always", (), False),
            ("missing default does not imply trust", None, (), True),
            ("nearest approval overrides parent denial", "never", ((root.parent, False), (root, True)), False),
            ("parent approval is inherited", "never", ((root.parent, True),), False),
            ("project bytes cannot trust their own directory", "never", (), True),
        ):
            set_policy(default, entries)
            probe(label, warns)
        alias = base / "alias"
        if not alias.exists():
            alias.symlink_to(root, target_is_directory=True)
        set_policy(None, [(root.parent, True), (root, None)])
        probe("a symlink launch resolves the real directory and inherits trust past a null decision", False, alias)

        # The readable "project bytes" row above is the warning-producing control.
        for label, path in (("trust", trust), ("settings", settings), ("project", project_file)):
            set_policy("never")
            contents = path.read_text()
            path.unlink()
            probe(f"missing {label} file suppresses the notice", False)
            path.write_text(contents)
            path.chmod(0)
            try:
                probe(f"unreadable {label} file suppresses the notice", False)
            finally:
                path.chmod(0o600)
        for label, malformed in (("invalid JSON", "not JSON"), ("non-object root", "[]"), ("non-boolean decision", '{"bad": 1}')):
            trust.write_text(malformed)
            probe(f"{label} in trust suppresses the notice", False)
        # From $HOME the project harness path is user scope: the user harness
        # itself, or the fixed permissions directory a custom configDir
        # leaves behind, holding a readable user permissions file.
        permissions = user_home / ".config/kimchi/harness/permissions.json"
        permissions.parent.mkdir(parents=True, exist_ok=True)
        permissions.write_text("{}")
        write_trust([])
        if relative != ".config/kimchi/harness":
            # Other launchers' runs leave their user harness files in the fixed
            # directory; only permissions.json belongs to this configuration.
            for leftover in permissions.parent.iterdir():
                if leftover != permissions:
                    leftover.unlink()
        probe("user-scope harness and permissions at HOME are not project files", False, user_home)
        # A moved configDir leaves the fixed directory holding only the user
        # permissions.json: it alone stays silent, but any other readable file
        # there is a project file and warns.
        if relative != ".config/kimchi/harness":
            fixed_settings = permissions.with_name("settings.json")
            fixed_settings.write_text("{}")
            probe("under a moved configDir, an extra fixed harness file is a project file at HOME", True, user_home)
            fixed_settings.unlink()
        project_file.unlink()
