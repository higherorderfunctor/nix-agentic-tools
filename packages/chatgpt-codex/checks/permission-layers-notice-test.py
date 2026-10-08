"""Exercise the permission-layers notice through a module launcher, with absence controls."""

import os
import subprocess
import sys
from pathlib import Path

launcher = sys.argv[1]
project_root = Path(os.environ["TMPDIR"]) / "project"
project = project_root / ".codex/config.toml"
project.parent.mkdir(parents=True)
user = Path(os.environ["CODEX_HOME"]) / "config.toml"
user.parent.mkdir()
legacy = 'sandbox_mode = "workspace-write"\n'
named = 'default_permissions = "work"\n[permissions.work]\n'


def launch():
    result = subprocess.run([launcher], cwd=project_root, capture_output=True, text=True, check=True)
    assert result.stdout == "", result
    # The launcher also warns that nothing trusts this project; that notice
    # has its own test.
    return "\n".join(line for line in result.stderr.splitlines() if not line.startswith("warning: Codex ignores"))


def probe(project_text, user_text, winner=None):
    for path, text in ((project, project_text), (user, user_text)):
        if path.exists():
            path.unlink()
        if text is not None:
            path.write_text(text)
    stderr = launch()
    if winner is None:
        assert stderr == "", stderr
    else:
        assert "warning: Codex permission models differ:" in stderr
        assert str(project) in stderr and str(user) in stderr
        assert f"{winner}'s" in stderr, stderr


probe(named, legacy, project)
probe(legacy, named, project)
probe('[permissions.work]\n', '[sandbox_workspace_write]\nwritable_roots = []\n')
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
assert launch() == ""
user.rmdir()
probe(named, legacy, project)
user.chmod(0)
try:
    assert launch() == ""
finally:
    user.chmod(0o600)
