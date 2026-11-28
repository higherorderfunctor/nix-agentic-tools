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
    alias = root / "alias"
    alias.mkdir()
    absent = root / "absent"
    for name, script in zip(sys.argv[1::2], sys.argv[2::2], strict=True):
        expected_bin = profile / "bin" / name
        shadowing_bin = global_bin / name
        for binary in (expected_bin, shadowing_bin):
            binary.write_text("runtime fixture\n")
            binary.chmod(0o755)
        (alias / name).symlink_to(expected_bin)

        def probe(case, paths, *, profile_is_set=True, warns=False):
            env = dict(os.environ, PATH=os.pathsep.join(map(str, paths)))
            env.pop("DEVENV_PROFILE", None)
            if profile_is_set:
                env["DEVENV_PROFILE"] = str(profile)
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

        # Both binaries are visible in the precedence cases; only order changes.
        probe("global binary first warns exactly once", (global_bin, profile / "bin"), warns=True)
        probe("no PATH match stays silent and exits zero", (absent,))
        probe("profile binary first is not shadowed", (profile / "bin", global_bin))
        probe("symlink to the profile binary is not shadowing", (alias, global_bin))
        probe("unset profile does not abort the strict-mode caller", (global_bin,), profile_is_set=False)
        expected_bin.unlink()
        probe("existing profile without this binary is not shadowed", (global_bin,))
