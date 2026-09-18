"""Run real Kiro writers through ownership handoffs and secret failures."""

import json
import os
import stat
import subprocess
import sys
from pathlib import Path


def snapshot(path):
    return path.read_bytes(), stat.S_IMODE(path.stat().st_mode), path.stat().st_mtime_ns


def exercise(case, bash):
    root = Path.cwd() / case["backend"]
    home, project, state = root / "home", root / "project", root / "state"
    target_root = home if case["backend"] == "hm" else project
    target_root.mkdir(parents=True)
    subdir = target_root / "subdir"
    subdir.mkdir()
    config = target_root / ".kiro/settings/mcp.json"
    environment = dict(os.environ, HOME=str(home), XDG_STATE_HOME=str(state),
                       DEVENV_ROOT=str(project), DEVENV_STATE=str(state))
    ledger = state / "nix-agentic-tools"
    whole = ledger / "materialize/kiro-settings.manifest"
    leaf_dir = ledger / "json-settings"

    def leaves():
        return list(leaf_dir.glob("kiro-mcp-*.json"))

    def activate(name, succeeds=True):
        script = ('before_flags=$-\nbefore_options=$(set +o)\n'
                  + case["scripts"][name]
                  + '\ntest "$before_flags" = "$-"\n'
                  + 'test "$before_options" = "$(set +o)"\n'
                  + 'test -z "${KIRO_MCP_ALPHA_URL+x}"\n'
                  + 'test -z "${NAT_SETTINGS_JSON+x}"\n'
                  + 'echo later-entry-ran\n')
        result = subprocess.run([bash, "-e", "-c", script], cwd=subdir,
                                env=environment, capture_output=True, text=True)
        assert (result.returncode == 0) == succeeds, (name, result.stderr)
        if succeeds:
            assert "later-entry-ran" in result.stdout
        return result

    def read():
        return json.loads(config.read_text())

    def edit(value):
        temporary = config.with_suffix(".native")
        temporary.write_text(json.dumps(value))
        temporary.chmod(stat.S_IMODE(config.stat().st_mode))
        temporary.replace(config)

    # Overwrite -> merge releases the file claim without backing up/adopting
    # hand edits. Historical undeclared fields have no recoverable leaf ledger.
    activate("overwrite")
    assert whole.is_file() and not leaves()
    native = read()
    native["mcpServers"]["hand"] = {"url": "https://hand.invalid"}
    native["mcpServers"]["beta"]["url"] = "https://edited.invalid"
    edit(native)
    activate("mergeReduced")
    assert read() == native
    assert not whole.exists() and len(leaves()) == 1
    assert not list((ledger / "materialize").glob("*.bak/*"))
    assert stat.S_IMODE(config.stat().st_mode) == 0o444
    activate("mergeEmpty")
    del native["mcpServers"]["alpha"]
    assert read() == native and not leaves() and not whole.exists()

    # Merge -> overwrite drains leaf ownership, then takes the path. Returning
    # to empty merge cannot use a stale ledger to retract newly manual values.
    activate("merge")
    assert len(leaves()) == 1 and not whole.exists()
    activate("overwriteReduced")
    assert read() == case["second"] and not leaves() and whole.is_file()
    native = read()
    native["mcpServers"]["beta"] = {"url": "https://new-hand.invalid"}
    edit(native)
    activate("mergeEmpty")
    assert read() == native and not leaves() and not whole.exists()
    before = snapshot(config)
    activate("mergeEmpty")
    assert snapshot(config) == before

    # The empty overwrite transition still runs leaf retirement. A later
    # manual leaf at a retired path is unowned and must survive empty merge.
    activate("merge")
    native = read()
    native["mcpServers"]["hand"] = {"url": "https://hand.invalid"}
    edit(native)
    activate("overwriteEmpty")
    assert read() == {"mcpServers": {"hand": native["mcpServers"]["hand"]}}
    assert not leaves() and whole.read_bytes() == b""
    edit(native)
    activate("mergeEmpty")
    assert read() == native and not leaves() and not whole.exists()

    # Render secret URLs before stdin reconciliation, retaining header tokens.
    # Devenv deliberately starts in a subdirectory; HOME is NOT project root.
    secret_root = subdir if case["backend"] == "hm" else target_root
    secret = secret_root / "credential-url"
    secret.write_text("https://secret.invalid/mcp")
    activate("secret")
    alpha = read()["mcpServers"]["alpha"]
    assert alpha["url"] == "https://secret.invalid/mcp"
    assert alpha["headers"]["Authorization"] == "Bearer ${env:KIRO_MCP_ALPHA_AUTHORIZATION}"
    manifest, = leaves()
    managed_paths = json.loads(manifest.read_text())["managed_paths"]
    assert managed_paths, "secret reconciliation emitted an empty ownership ledger"
    assert all(path[0] == "mcpServers" for path in managed_paths)
    assert ["mcpServers", "alpha", "url"] in managed_paths
    assert ["mcpServers", "alpha", "headers", "Authorization"] in managed_paths
    before = snapshot(config), snapshot(manifest)
    for value in (None, "", 'invalid " JSON'):
        if value is None:
            secret.unlink()
        else:
            secret.write_text(value)
        activate("secret", succeeds=False)
        assert (snapshot(config), snapshot(manifest)) == before
    helper = secret_root / "failed-helper"
    helper.write_text(f"#!{bash}\nset -euETo pipefail\n"
                      "shopt -s inherit_errexit 2>/dev/null || :\n"
                      "printf 'https://partial.invalid'\nfalse\n")
    helper.chmod(0o700)
    activate("failedHelper", succeeds=False)
    assert (snapshot(config), snapshot(manifest)) == before
    assert not whole.exists()
    assert not list(config.parent.glob(".*.nat-tmp.*"))
    assert not (subdir / ".kiro").exists()
    if case["backend"] == "devenv":
        assert not home.exists()
    print(f"PASS: {case['backend']} mode switches, credentials, isolation")


cases = json.loads(Path(sys.argv[1]).read_text())
assert len(cases) == 2 and {case["backend"] for case in cases} == {"hm", "devenv"}
for case in cases:
    assert case["scripts"] and all(
        isinstance(script, str) and script.strip() for script in case["scripts"].values()
    ), f"{case['backend']}: missing activation body"
for case in cases:
    exercise(case, sys.argv[2])
