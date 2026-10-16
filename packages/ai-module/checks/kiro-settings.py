"""Run Kiro's evaluated copy plans on real directories, including URL rendering."""
import copy
import hashlib
import importlib.util
import json
import os
import runpy
from pathlib import Path
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location("files_engine", sys.argv[1])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
data = json.loads(Path(sys.argv[2]).read_text())
os.environ["FILES_BASH"] = data["bash"]

with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary)
    templates = {}
    for name, template in data["templates"].items():
        path = Path(template["path"])
        if not path.exists():
            path = base / f"{name}.json"
            path.write_text(template["text"])
        templates[template["path"]] = str(path)

    def plan_for(step):
        plan = copy.deepcopy(step["plan"])
        for item in plan:
            content = item["content"]
            # CI reads actual built output. Local runs substitute only missing
            # generated files, retaining the evaluated renderer and its tools.
            if "source" in content and not Path(content["source"]).exists():
                staged = step["inputs"][item["path"]]
                item["content"] = ({"source": staged["source"]} if staged["source"] else {"text": staged["text"]})
            elif "value" in content and not Path(content["rendered"]).exists():
                item["content"] = {"text": json.dumps(content["value"], separators=(",", ":"))}
            elif "run" in content:
                for original, path in templates.items():
                    content["run"] = content["run"].replace(original, path)
        return plan

    # The acceptance runner renders before launching a session. Its backend
    # environment must name the fixture root rather than the launch checkout.
    render_fixture = runpy.run_path(sys.argv[3])["render_fixture"]
    probe = base / "acceptance"
    probe.mkdir()
    (probe / "credential-url").write_text(data["plainUrl"])
    renderer = next(item for item in plan_for(data["fixture"]["devenv"]["secret"]) if item["content"].get("run"))
    os.environ["DEVENV_ROOT"] = str(base / "wrong-root")
    render_fixture({"files": [{"path": renderer["path"], "renderCommand": renderer["content"]["run"], "renderShell": data["bash"]}]}, probe, base / "acceptance-state")
    assert json.loads((probe / renderer["path"]).read_text())["mcpServers"]["demo"]["url"] == data["plainUrl"]
    print("PASS: acceptance renderer uses the fixture backend root")

    for backend, steps in data["fixture"].items():
        for disabled_first in (False, True):
            root = base / f"{backend}-{disabled_first}"
            root.mkdir()
            old = root / "state"
            state = old / "files/ai.json"
            os.environ.update(HOME=str(root), DEVENV_ROOT=str(root))
            os.chdir(root)
            for legacy in steps["disabled"]["legacyLedgers"]:
                directory = root / legacy["path"]
                directory.mkdir(parents=True)
                managed = directory / "old.json"
                managed.write_bytes(b"old\n")
                (directory / "unmanaged.json").write_bytes(b"keep\n")
                ledger = old / legacy["ledger"]
                ledger.parent.mkdir(parents=True, exist_ok=True)
                ledger.write_text("old.json\t" + hashlib.sha256(b"old\n").hexdigest() + "\n")
            target = root / ".kiro/settings/mcp.json"
            target.write_text('{"foreign":true}\n')
            original = target.read_bytes()
            cli = root / ".kiro/settings/cli.json"
            feed = root / ".kiro/settings/feed_state.json"
            feed.write_bytes(b'{"lastFeedCheck":1}\n')

            def phase(name, action):
                step = steps[name]
                engine.reconcile(plan_for(step), root, state, action, step["legacyLedgers"], old)

            def activate(name):
                phase(name, "prune")
                phase(name, "apply")
                assert state.exists() == bool(steps[name]["plan"])
                records = json.loads(state.read_text())["files"] if steps[name]["plan"] else {}
                assert set(records) == {item["path"] for item in steps[name]["plan"]}
                for item in steps[name]["plan"]:
                    path = root / item["path"]
                    record = records[item["path"]]
                    assert path.is_file() and not path.is_symlink()
                    assert path.stat().st_mode & 0o777 == int(item["mode"] or "0444", 8)
                    assert record["digest"] == hashlib.sha256(path.read_bytes()).hexdigest()
                    assert record["method"] == "ro" and record["keys"] == {}
                    if "/hooks/" in item["path"]:
                        staged = steps[name]["inputs"][item["path"]]
                        expected = Path(staged["source"]).read_text() if staged["source"] else staged["text"]
                        assert json.loads(path.read_text()) == json.loads(expected)
                for legacy in steps[name]["legacyLedgers"]:
                    assert not (old / legacy["ledger"]).exists()
                    assert not (root / legacy["path"] / "old.json").exists()
                    assert (root / legacy["path"] / "unmanaged.json").read_bytes() == b"keep\n"

            activate("disabled" if disabled_first else "empty")
            assert (json.loads(target.read_text()) == {"mcpServers": {}} if backend == "hm" and not disabled_first else target.read_bytes() == original)
            if disabled_first:
                assert not state.exists()
                print(f"PASS: {backend} disabled-first: all legacy ledgers drained, foreign files preserved")
                continue
            activate("plain")
            assert json.loads(target.read_text())["mcpServers"]["demo"]["url"] == data["plainUrl"]
            assert any(path.read_bytes() == original for path in state.parent.glob("*.bak"))
            before = target.read_bytes()
            os.utime(target, (946684800, 946684800))
            activate("plain")
            assert target.stat().st_mtime == 946684800
            (root / "credential-url").write_text(data["plainUrl"])
            activate("private")
            assert target.read_bytes() == before and target.stat().st_mode & 0o777 == 0o400
            activate("plain")
            assert target.read_bytes() == before and target.stat().st_mode & 0o777 == 0o444
            (root / "credential-url").unlink()
            # Simulate the application's rename over cli.json and preserve its neighbor.
            replacement = cli.with_suffix(".tmp")
            replacement.write_bytes(b'{"chat.defaultModel":"in-app"}')
            replacement.chmod(0o600)
            replacement.replace(cli)
            activate("plain")
            assert json.loads(cli.read_text()) == {"chat.enableTangentMode": True}
            assert feed.read_bytes() == b'{"lastFeedCheck":1}\n'
            assert sum(path.read_bytes() == b'{"chat.defaultModel":"in-app"}' for path in state.parent.glob("*.bak")) == 1
            # Renderer runs only in apply, after the provider writes its secret.
            phase("secret", "prune")
            assert not (root / "credential-url").exists() and target.read_bytes() == before
            (root / "credential-url").write_text(data["plainUrl"])
            (root / "subdir").mkdir()
            os.chdir(root / "subdir")
            if backend == "hm":
                # HM retains activation cwd; devenv alone anchors relative readers.
                (root / "subdir/credential-url").write_text(data["plainUrl"])
            phase("secret", "apply")
            assert target.stat().st_mode & 0o777 == 0o400
            assert json.loads(target.read_text())["mcpServers"]["demo"]["headers"]["X-Token"] == "${env:KIRO_MCP_DEMO_X_TOKEN}"
            assert not (root / "subdir/.kiro").exists()
            os.chdir(root)
            activate("plain")
            assert target.stat().st_mode & 0o777 == 0o444 and target.read_bytes() == before
            for failure in ("missing", "empty", "helper"):
                credential = root / "credential-url"
                if credential.exists():
                    credential.unlink()
                if failure == "empty":
                    credential.touch()
                helper = root / "failed-helper"
                helper.write_text(f'#!{data["bash"]}\nset -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\nprintf partial-secret\nfalse\n')
                helper.chmod(0o755)
                name = "helper" if failure == "helper" else "secret"
                phase(name, "prune")
                snapshot = state.read_bytes()
                try:
                    phase(name, "apply")
                except subprocess.CalledProcessError:
                    pass
                else:
                    raise AssertionError(f"{failure} renderer succeeded")
                assert target.read_bytes() == before and state.read_bytes() == snapshot
                assert not list(target.parent.glob(".files-*"))
            for name in ("plain", "secret", "directory", "empty", "disabled"):
                (root / "credential-url").write_text(data["plainUrl"])
                activate(name)
                assert {path.name for path in (root / ".kiro/hooks").iterdir()} == {"unmanaged.json"} | {
                    Path(item["path"]).name for item in steps[name]["plan"] if "/hooks/" in item["path"]}
            assert not target.exists() and not cli.exists()
            target.mkdir()
            try:
                activate("plain")
            except ValueError as error:
                assert "special file refused" in str(error)
            else:
                raise AssertionError("directory collision accepted")
            assert target.is_dir() and ".kiro/settings/mcp.json" not in json.loads(state.read_text())["files"]
            target.rmdir()
            target.write_bytes(original)
            activate("disabled")
            assert target.read_bytes() == original
            print(f"PASS: {backend}: bytes, state, modes, restore, failures, provider, roots, hook transitions, retirement")
