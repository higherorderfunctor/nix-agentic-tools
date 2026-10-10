"""Offline session trust controls against rendered launchers and pinned Codex."""

import json
import os
import subprocess
import sys
import tomllib
from pathlib import Path

stub_off, stub_on, codex_off, codex_on = sys.argv[1:]
root = Path(os.environ["TMPDIR"]) / r'repo.with.dot 😀 and space "quote" \ slash'
root.mkdir()
(root / ".codex").mkdir()
(root / ".codex/config.toml").write_text("project_doc_max_bytes = 32\n")
(root / "AGENTS.md").write_text("Q" * 512 + "END_OF_PROBE")
home = root.parent / "home"
home.mkdir()
codex_home = home / ".codex"
codex_home.mkdir()
user = codex_home / "config.toml"
user.write_text("")
environment = os.environ | {"CODEX_HOME": str(codex_home), "DEVENV_ROOT": str(root), "HOME": str(home)}


def launch(binary, *arguments):
    return subprocess.run([binary, *arguments], cwd=root, env=environment, capture_output=True, text=True, check=True)


for binary, trusted in ((stub_off, False), (stub_on, True)):
    result = launch(binary, "--version")
    arguments = json.loads(result.stdout)
    overrides = [arguments[index + 1] for index, argument in enumerate(arguments) if argument == "-c"]
    if trusted:
        assert len(overrides) == 1, arguments
        assert overrides[0].startswith("projects={"), overrides
        assert tomllib.loads(overrides[0]) == {"projects": {str(root): {"trust_level": "trusted"}}}
    else:
        assert overrides == [], arguments
    # --version skips notices; a normal command proves preflight sees trust.
    notice = launch(binary, "debug", "prompt-input", "PROBE")
    assert ("warning: Codex ignores" in notice.stderr) == (not trusted), notice.stderr

for binary, trusted in ((codex_off, False), (codex_on, True)):
    result = launch(binary, "debug", "prompt-input", "PROBE")
    expected_count = 32 if trusted else 512
    assert result.stdout.count("Q") == expected_count, result.stdout
    assert ("END_OF_PROBE" in result.stdout) == (not trusted), result.stdout
    assert ("warning: Codex ignores" in result.stderr) == (not trusted), result.stderr
    assert user.read_text() == "", "launcher changed user config"
    print(f"verified: session trust={trusted}, Q_count={expected_count}, user config unchanged")
