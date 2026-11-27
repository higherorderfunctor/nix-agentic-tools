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
    names = ("claude", "codex", "kimchi", "kiro-cli")
    for name in names:
        for binary in (profile / "bin" / name, global_bin / name):
            binary.write_text("runtime fixture\n")
            binary.chmod(0o755)

    alias = root / "alias"
    alias.mkdir()
    absent = root / "absent"
    for script, name in zip(sys.argv[1:], names, strict=True):
        expected_bin = profile / "bin" / name
        shadowing_bin = global_bin / name
        (alias / name).symlink_to(expected_bin)

        def probe(case, path, selected_profile, *, warns=False):
            env = dict(os.environ, PATH=str(path), DEVENV_PROFILE=str(selected_profile))
            result = subprocess.run([script], env=env, capture_output=True, text=True)
            label = f"{name}: {case}"
            assert result.returncode == 0, (label, result)
            assert result.stdout == "", (label, result.stdout)
            if warns:
                lines = result.stderr.splitlines()
                prefix = f"warning: {name} on PATH is {shadowing_bin}, not the devenv profile copy {expected_bin}."
                assert len(lines) == 1 and lines[0].startswith(prefix), (label, result.stderr)
            else:
                assert result.stderr == "", (label, result.stderr)

        # All silent cases share this positive control for the same runtime.
        probe("global binary shadows the profile", global_bin, profile, warns=True)
        for case, path, selected_profile in (
            ("no PATH match", absent, profile),
            ("no declared profile", global_bin, ""),
            ("nonexistent profile", global_bin, absent),
            ("profile binary is first on PATH", profile / "bin", profile),
            ("symlink resolves to the profile binary", alias, profile),
        ):
            probe(case, path, selected_profile)
        expected_bin.unlink()
        probe("existing profile has no runtime binary", global_bin, profile)
