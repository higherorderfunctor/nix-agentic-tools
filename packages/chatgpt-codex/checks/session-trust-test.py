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

# Parse the real argv payload: TOML quoting must preserve the literal path.
arguments = json.loads(launch(stub_on, "--version").stdout)
assert [override for override in config_overrides(arguments) if override[0] == "-c"] == [
    ("-c", {"projects": {str(root): {"trust_level": "trusted"}}}),
], ("opt-in must preserve a path with spaces, quotes and a backslash", arguments)

# The pinned CLI must load the project limit only for opted-in sessions;
# preflight must agree and neither launcher may write persistent user trust.
target = root / ".codex/config.toml"
for case, binary, expected_count, expected_tail, expected_warnings in (
    ("opt-out ignores the project limit and preserves the document tail", codex_off, 512, True, [
        f"warning: Codex ignores {target} because this project is not trusted in {user}. "
        "Set the project trust_level to trusted in the user config to load the delivered config."
    ]),
    ("opt-in applies the project limit without persisting trust", codex_on, 32, False, []),
):
    result = launch(binary, "debug", "prompt-input", "PROBE")
    # Measure the AGENTS.md probe's run, not every "Q": Codex's own prompt text
    # carries capital Qs too ("Questions to show the user" from 0.164.0).
    probe_run = max(map(len, re.findall("Q+", result.stdout)), default=0)
    assert probe_run == expected_count, (case, probe_run)
    assert ("END_OF_PROBE" in result.stdout) == expected_tail, case
    trust_warnings = [line for line in result.stderr.splitlines() if line.startswith("warning: Codex ignores ")]
    assert trust_warnings == expected_warnings, (case, result.stderr)
    assert user.read_text() == "", (case, "launcher changed user config")
    print(f"verified: {case}")
