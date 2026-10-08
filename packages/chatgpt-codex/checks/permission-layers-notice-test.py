"""Exercise the module's rendered shell-entry command, including absence controls."""

import os
import subprocess
import sys
from pathlib import Path

project = Path(os.environ["DEVENV_ROOT"]) / ".codex/config.toml"
user = Path(os.environ["CODEX_HOME"]) / "config.toml"
legacy = 'sandbox_mode = "workspace-write"\n'
named = 'default_permissions = "work"\n[permissions.work]\n'


def probe(project_text, user_text, winner=None):
    for path, text in ((project, project_text), (user, user_text)):
        if path.exists():
            path.unlink()
        if text is not None:
            path.write_text(text)
    result = subprocess.run([sys.argv[1]], capture_output=True, text=True, check=True)
    assert result.stdout == "", result
    if winner is None:
        assert result.stderr == "", result.stderr
    else:
        assert "warning: Codex permission models differ:" in result.stderr
        assert str(project) in result.stderr and str(user) in result.stderr
        assert f"{winner}'s" in result.stderr, result.stderr


probe(named, legacy, project)
probe(legacy, named, project)
probe('[sandbox_workspace_write]\nwritable_roots = []\n', named, user)
probe('[permissions.work]\n', legacy, user)
for same in (legacy, named, ""):
    probe(same, same)
# Every missing/unreadable-input case follows a warning-producing control.
for missing_project, missing_user in ((None, legacy), (named, None), (None, None)):
    probe(named, legacy, project)
    probe(missing_project, missing_user)
for invalid in ('not toml!', '# sandbox_mode = "workspace-write"\n', '[other]\nsandbox_mode = "workspace-write"\n'):
    probe(named, legacy, project)
    probe(named, invalid)
probe(named, legacy, project)
user.unlink()
user.mkdir()
result = subprocess.run([sys.argv[1]], capture_output=True, text=True, check=True)
assert result.stdout == result.stderr == "", result
user.rmdir()
probe(named, legacy, project)
user.chmod(0)
try:
    result = subprocess.run([sys.argv[1]], capture_output=True, text=True, check=True)
    assert result.stdout == result.stderr == "", result
finally:
    user.chmod(0o600)
