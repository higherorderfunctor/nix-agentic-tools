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

    def plan_for(step, root):
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
                content["run"] = content["run"].replace("/run/redact-fixture/", str(root) + "/")
                for original, path in templates.items():
                    content["run"] = content["run"].replace(original, path)
        return plan

    # The acceptance runner renders before launching a session. Its backend
    # environment must name the fixture root rather than the launch checkout.
    render_fixture = runpy.run_path(sys.argv[3])["render_fixture"]
    probe = base / "acceptance"
    probe.mkdir()
    (probe / "credential-url").write_text(data["plainUrl"])
    renderer = next(item for item in plan_for(data["fixture"]["devenv"]["secret"], probe) if item["content"].get("run"))
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
                engine.reconcile(plan_for(step, root), root, state, action, step["legacyLedgers"], old)

            def activate(name):
                phase(name, "prune")
                phase(name, "apply")
                if not steps[name]["plan"]:
                    assert not state.exists()
                records = json.loads(state.read_text())["files"] if steps[name]["plan"] else {}
                assert set(records) == {item["path"] for item in steps[name]["plan"]}
                for item in steps[name]["plan"]:
                    path = root / item["path"]
                    record = records[item["path"]]
                    assert path.is_file() and not path.is_symlink()
                    assert path.stat().st_mode & 0o777 == int(item["mode"] or "0444", 8)
                    assert record["method"] == "ro"
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
            assert target.read_bytes() == before
            activate("plain")
            assert target.read_bytes() == before
            (root / "credential-url").unlink()
            # Simulate the application's rename over cli.json and preserve its neighbor.
            replacement = cli.with_suffix(".tmp")
            replacement.write_bytes(b'{"chat.defaultModel":"in-app"}')
            replacement.chmod(0o600)
            replacement.replace(cli)
            activate("plain")
            expected_cli = {"chat.enableTangentMode": True}
            # The updater setting is user-global, so only Home Manager writes it.
            if backend == "hm":
                expected_cli["app.disableAutoupdates"] = True
            assert json.loads(cli.read_text()) == expected_cli
            assert feed.read_bytes() == b'{"lastFeedCheck":1}\n'
            assert sum(path.read_bytes() == b'{"chat.defaultModel":"in-app"}' for path in state.parent.glob("*.bak")) == 1
            # Renderer runs only in apply, after the provider writes its secret.
            phase("secret", "prune")
            assert target.read_bytes() == before
            (root / "credential-url").write_text(data["plainUrl"])
            (root / "subdir").mkdir()
            os.chdir(root / "subdir")
            phase("secret", "apply")
            assert target.stat().st_mode & 0o777 == 0o400
            assert json.loads(target.read_text())["mcpServers"]["demo"]["headers"]["X-Token"] == "${env:KIRO_MCP_DEMO_HEADER_X_TOKEN}"
            assert not (root / "subdir/.kiro").exists()
            os.chdir(root)
            activate("plain")
            assert target.read_bytes() == before
            failures = {
                "empty": "reference resolved empty",
                "helper": "reference command failed",
                "missing": "reference file is missing",
            }
            helper = root / "failed-helper"
            helper.write_text(f'#!{data["bash"]}\nset -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\nprintf partial-secret\nfalse\n')
            helper.chmod(0o755)
            failed_plan = root / "failed-plan.json"
            for failure, diagnostic in failures.items():
                credential = root / "credential-url"
                credential.unlink(missing_ok=True)
                if failure == "empty":
                    credential.touch()
                name = "helper" if failure == "helper" else "secret"
                phase(name, "prune")
                snapshot = state.read_bytes()
                failed_plan.write_text(json.dumps(plan_for(steps[name], root)))
                result = subprocess.run(
                    [sys.executable, "-I", sys.argv[1], "--plan", str(failed_plan),
                     "--root", str(root), "--state", str(state), "--phase", "apply",
                     "--legacy-plan", json.dumps(steps[name]["legacyLedgers"]), "--legacy-state", str(old)],
                    capture_output=True, text=True,
                )
                expected_error = f"ai.kiro.mcpServers URL KIRO_MCP_DEMO_URL: {diagnostic}"
                assert result.returncode == 1 and expected_error in result.stderr.splitlines(), (failure, result.stderr)
                if failure == "helper":
                    assert "partial-secret" not in result.stderr, failure
                assert target.read_bytes() == before and state.read_bytes() == snapshot
                assert not list(target.parent.glob(".files-*"))
            # Typed hooks shrink, then give way to the directory hook, then retire.
            hook_steps = [
                ("plain", {"alpha.json", "beta.json"}),
                ("secret", {"alpha.json"}),
                ("directory", {"sample.json"}),
                ("empty", set()),
            ]
            if backend == "hm":
                hook_steps.append(("disabled", set()))
            for name, hooks in hook_steps:
                (root / "credential-url").write_text(data["plainUrl"])
                activate(name)
                assert {path.name for path in (root / ".kiro/hooks").iterdir()} == {"unmanaged.json"} | hooks, name
            assert not target.exists() and not cli.exists()
            target.mkdir()
            try:
                activate("plain")
            except ValueError as error:
                assert "special file refused" in str(error)
            else:
                raise AssertionError("directory collision accepted")
            assert target.is_dir() and ".kiro/settings/mcp.json" not in json.loads(state.read_text())["files"]
            print(f"PASS: {backend}: bytes, state, modes, restore, failures, provider, roots, hook transitions, retirement")
