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
catalog = '[permissions.work]\n'
roots = '[sandbox_workspace_write]\nwritable_roots = []\n'
legacy = 'sandbox_mode = "workspace-write"\n'
named = 'default_permissions = "work"\n[permissions.work]\n'


def launch():
    result = subprocess.run([launcher], cwd=project_root, capture_output=True, text=True, check=True)
    assert result.stdout == "", result
    # The launcher also warns that nothing trusts this project; that notice
    # has its own test.
    return "\n".join(line for line in result.stderr.splitlines() if not line.startswith("warning: Codex ignores"))


def probe(case, project_text, user_text, expected=None):
    for path, text in ((project, project_text), (user, user_text)):
        path.unlink(missing_ok=True)
        if text is not None:
            path.write_text(text)
    stderr = launch()
    if expected is None:
        assert stderr == "", (case, stderr)
    else:
        user_model, project_model, winner, winning_model = expected
        assert len(stderr.splitlines()) == 1, (case, stderr)
        for claim in (
            "warning: Codex permission models differ:",
            f"{user} uses {user_model};",
            f"{project} uses {project_model}.",
            f"{winner}'s {winning_model} wins;",
        ):
            assert claim in stderr, (case, claim, stderr)


legacy_model = "legacy sandbox"
named_model = "named permissions"
# The first row is also a warning-producing control for the silence cases.
for row in (
    ("project named selector beats user legacy selector", named, legacy, (legacy_model, named_model, project, named_model)),
    ("project legacy selector beats user named selector", legacy, named, (named_model, legacy_model, project, legacy_model)),
    ("neither project's catalog nor user's roots select a model", catalog, roots),
    ("project roots are not a selector over user named permissions", roots, named, (named_model, legacy_model, user, named_model)),
    ("project catalog is not a selector over user legacy sandbox", catalog, legacy, (legacy_model, named_model, user, legacy_model)),
    ("two legacy selectors do not conflict", legacy, legacy),
    ("two named selectors do not conflict", named, named),
    ("empty configs do not select a default model", "", ""),
    ("absent project config cannot conflict with user legacy", None, legacy),
    ("absent user config cannot conflict with project named", named, None),
    ("commented selector is not a setting", named, '# sandbox_mode = "workspace-write"\n'),
    ("nested selector is not a top-level setting", named, '[other]\nsandbox_mode = "workspace-write"\n'),
):
    probe(*row)

probe("readable user legacy conflicts with project named", named, legacy, (legacy_model, named_model, project, named_model))
user.chmod(0)
try:
    stderr = launch()
    assert stderr == "", ("unreadable existing user config is silent", stderr)
finally:
    user.chmod(0o600)
