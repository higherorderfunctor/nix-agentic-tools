"""Offline session trust controls against rendered launchers and pinned Codex,
and the effective check_for_update_on_startup as a --config session flag that a
later user -c overrides.
"""

import json
import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path

stub_off, stub_on, codex_off, codex_on, stub_update_true, stub_update_null = sys.argv[1:]
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


def config_overrides(arguments):
    return [
        (flag, tomllib.loads(arguments[index + 1]))
        for index, flag in enumerate(arguments)
        if flag in ("--config", "-c")
    ]


# Pin the spellings as well as the values: an extra -c could override the
# managed value, and null must leave no update override on the command line.
for case, binary, expected in (
    ("unset defaults to false", stub_off, [("--config", {"check_for_update_on_startup": False})]),
    ("explicit true replaces the false default", stub_update_true, [("--config", {"check_for_update_on_startup": True})]),
    ("explicit null omits the override", stub_update_null, []),
):
    arguments = json.loads(launch(binary, "--version").stdout)
    assert config_overrides(arguments) == expected, (case, arguments)
    print(f"verified: update-check session override: {case}")

arguments = json.loads(launch(stub_off, "-c", "check_for_update_on_startup=true", "--version").stdout)
assert config_overrides(arguments) == [
    ("--config", {"check_for_update_on_startup": False}),
    ("-c", {"check_for_update_on_startup": True}),
], ("user override must follow launcher default", arguments)
print("verified: user -c overrides the launcher update-check default")

# Parse the real argv payload: TOML quoting must preserve the literal path,
# and an opt-out must not silently inject a project trust override.
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

# The pinned CLI must load the project limit only for opted-in sessions;
# preflight must agree and neither launcher may write persistent user trust.
for binary, trusted in ((codex_off, False), (codex_on, True)):
    result = launch(binary, "debug", "prompt-input", "PROBE")
    expected_count = 32 if trusted else 512
    # Measure the AGENTS.md probe's run, not every "Q": Codex's own prompt text
    # carries capital Qs too ("Questions to show the user" from 0.164.0).
    probe_run = max(map(len, re.findall("Q+", result.stdout)), default=0)
    assert probe_run == expected_count, result.stdout
    assert ("END_OF_PROBE" in result.stdout) == (not trusted), result.stdout
    target = root / ".codex/config.toml"
    trust_warnings = [line for line in result.stderr.splitlines() if line.startswith("warning: Codex ignores ")]
    assert len(trust_warnings) == (0 if trusted else 1), (trusted, result.stderr)
    if not trusted:
        assert trust_warnings[0].startswith(f"warning: Codex ignores {target} "), result.stderr
    assert user.read_text() == "", "launcher changed user config"
    print(f"verified: session trust={trusted}, Q_count={expected_count}, user config unchanged")
