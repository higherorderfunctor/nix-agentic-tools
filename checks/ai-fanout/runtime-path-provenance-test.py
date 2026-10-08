"""Run each runtime's rendered notice against matching and shadowed PATHs."""

import os
import subprocess
import sys
import tempfile
from pathlib import Path

with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    profile, global_bin = root / "profile", root / "global/bin"
    (profile / "bin").mkdir(parents=True)
    global_bin.mkdir(parents=True)
    for name in ("claude", "codex", "copilot", "kimchi", "kiro-cli"):
        for binary in (profile / "bin" / name, global_bin / name):
            binary.write_text("runtime fixture\n")
            binary.chmod(0o755)

    for script, name in zip(sys.argv[1:], ("claude", "codex", "copilot", "kimchi", "kiro-cli"), strict=True):
        def probe(path, selected_profile, warning=False):
            env = dict(os.environ, PATH=str(path), DEVENV_PROFILE=str(selected_profile))
            result = subprocess.run([script], env=env, capture_output=True, text=True, check=True)
            assert result.stdout == "", result
            if warning:
                assert f"warning: {name} on PATH is {global_bin / name}" in result.stderr
                assert str(profile / "bin" / name) in result.stderr
            else:
                assert result.stderr == "", result.stderr

        probe(global_bin, profile, True)
        probe(profile / "bin", profile)
        # Different spellings of the same binary must stay silent.
        alias = root / "alias"
        alias.mkdir(exist_ok=True)
        (alias / name).symlink_to(profile / "bin" / name)
        probe(alias, profile)
        # Every missing-input test has a shadowed-path positive control.
        for path, selected_profile in ((global_bin, ""), (root / "absent", profile), (global_bin, root / "absent")):
            probe(global_bin, profile, True)
            probe(path, selected_profile)
        probe(global_bin, profile, True)
        (profile / "bin" / name).unlink()
        probe(global_bin, profile)
