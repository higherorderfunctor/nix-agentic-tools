"""Execute Kimchi copy, shared-document and activation-renderer generations."""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location("files2_engine", sys.argv[1])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
data = json.loads(Path(sys.argv[2]).read_text())
os.environ["FILES2_BASH"] = data["bash"]

def restored(actual, declared):
    for key, value in declared.items():
        if isinstance(value, dict):
            restored(actual[key], value)
        else:
            assert actual[key] == value


with tempfile.TemporaryDirectory() as temporary:
    base = Path(temporary)
    (base / "real/project").mkdir(parents=True)
    (base / "link").symlink_to("real", target_is_directory=True)
    trust_input = base / "trust-input.json"
    trust = {key.replace("/kimchi-fixture", str(base)): value for key, value in data["trust"].items()}
    trust_input.write_text(json.dumps(trust))

    for backend, directories in data["fixture"].items():
        for index, steps in enumerate(directories.values()):
            for scenario in ("legacy", "disabled-first", "secret" if backend == "hm" else "renderer"):
                root = base / f"{backend}-{index}-{scenario}"
                root.mkdir()
                os.environ.update(HOME=str(root), DEVENV_ROOT=str(root))
                os.chdir(root)
                state, old = root / "state/files2/ai.json", root / "state"
                config_path = root / steps["plain"]["configPath"]
                harness = root / steps["plain"]["harnessDir"]
                legacy = steps["disabled"]["legacyLedgers"]
                if scenario in ("legacy", "disabled-first"):
                    for entry in legacy:
                        target = root / entry["path"]
                        ledger = old / entry["ledger"]
                        ledger.parent.mkdir(parents=True, exist_ok=True)
                        if entry["codec"] == "dir":
                            target.mkdir(parents=True, exist_ok=True)
                            (target / "old.json").write_text("old\n")
                            (target / "unmanaged.json").write_text("keep\n")
                            ledger.write_text("old.json\t" + hashlib.sha256(b"old\n").hexdigest() + "\n")
                        else:
                            target.parent.mkdir(parents=True, exist_ok=True)
                            target.write_text('{"retired":true,"native":"keep"}')
                            target.chmod(0o600)
                            ledger.write_text('{"version":1,"managed_paths":[["retired"]]}')

                def plan_for(name):
                    step = steps[name]
                    plan = copy.deepcopy(step["plan"])
                    template = base / "config-input.json"
                    template.write_text(json.dumps(step["template"]["value"]))
                    for item in plan:
                        content = item["content"]
                        if "value" in content and not Path(content["rendered"]).exists():
                            # Each declaration has a distinct rendered input.
                            rendered = root / f"value-{len(item['path'])}-{Path(item['path']).name}"
                            rendered.write_text(json.dumps(content["value"]))
                            content["rendered"] = str(rendered)
                        elif "run" in content:
                            content["run"] = content["run"].replace(data["trustPath"], str(trust_input)).replace(step["template"]["path"], str(template))
                            content["run"] = re.sub(r"/nix/store/[^\s]+/bin/python3", sys.executable, content["run"])
                    return plan

                def phase(name, action):
                    engine.reconcile(plan_for(name), root, state, action, legacy, old)

                def activate(name):
                    phase(name, "prune")
                    phase(name, "apply")
                    assert state.exists() == bool(steps[name]["plan"])
                    records = json.loads(state.read_text())["files"] if steps[name]["plan"] else {}
                    assert set(records) == {item["path"] for item in steps[name]["plan"]}
                    for item in steps[name]["plan"]:
                        target = root / item["path"]
                        record = records[item["path"]]
                        assert target.is_file() and not target.is_symlink()
                        mode = int(item["mode"], 8) if item["mode"] else (0o600 if item["method"] == "rw" else 0o444)
                        assert target.stat().st_mode & 0o777 == mode
                        assert record["method"] == item["method"] and record["format"] == "json"
                        assert record["digest"] == hashlib.sha256(target.read_bytes()).hexdigest()
                        if item["method"] == "ro":
                            assert record["keys"] == {}
                            if "value" in item["content"]:
                                assert json.loads(target.read_text()) == item["content"]["value"]
                            try:
                                target.write_text("in-place edit")
                            except PermissionError:
                                pass
                            else:
                                raise AssertionError("read-only copy accepted in-place write")
                        else:
                            assert record["keys"] and "/native" not in record["keys"] and "/retired" not in record["keys"]
                            if scenario == "legacy":
                                assert not record["created"]
                            restored(json.loads(target.read_text()), item["content"]["value"])
                    for entry in legacy:
                        assert not (old / entry["ledger"]).exists()
                        if scenario in ("legacy", "disabled-first") and entry["codec"] == "dir":
                            assert not (root / entry["path"] / "old.json").exists()
                            assert (root / entry["path"] / "unmanaged.json").read_text() == "keep\n"

                if scenario == "disabled-first":
                    activate("disabled")
                    for entry in legacy:
                        if entry["codec"] == "json":
                            assert json.loads((root / entry["path"]).read_text()) == {"native": "keep"}
                    assert not state.exists()
                elif scenario == "legacy":
                    mcp = harness / "mcp.json" if backend == "hm" else root / ".kimchi/mcp.json"
                    mcp.parent.mkdir(parents=True, exist_ok=True)
                    mcp.write_text('{"mcpServers":{"migrated":{}}}')
                    activate("plain")
                    assert sum(path.read_text() == '{"mcpServers":{"migrated":{}}}' for path in state.parent.glob("*.bak")) == 1
                    for item in steps["plain"]["plan"]:
                        target = root / item["path"]
                        value = json.loads(target.read_text())
                        if item["method"] == "rw":
                            value.update(native="keep", **({"region": "eu"} if target == config_path else {"theme": "dark"}))
                            target.write_text(json.dumps(value))
                        else:
                            replacement = root / "replacement.json"
                            replacement.write_text('{"edited":true}')
                            replacement.replace(target)
                    activate("plain")
                    assert sum(path.read_text() == '{"edited":true}' for path in state.parent.glob("*.bak")) == sum(item["method"] == "ro" for item in steps["plain"]["plan"])
                    if backend == "hm":
                        assert json.loads(config_path.read_text())["region"] == "us"
                        assert json.loads(config_path.read_text())["native"] == "keep"
                        assert json.loads((harness / "settings.json").read_text())["theme"] == "kimchi-minimal"
                        assert json.loads((harness / "settings.json").read_text())["native"] == "keep"
                        trust_path = harness / "trust.json"
                        assert json.loads(trust_path.read_text()) == {str(base / "real/project"): True, "/nonexistent/kimchi-project": False}
                        before = trust_path.read_bytes()
                        trust_input.write_text(json.dumps({**trust, str(base / "real/project"): False}))
                        plan_path = root / "conflicting-trust-plan.json"
                        plan_path.write_text(json.dumps(plan_for("plain")))
                        result = subprocess.run([
                            sys.executable, "-I", str(Path(engine.__file__).resolve()),
                            "--plan", str(plan_path), "--root", str(root),
                            "--state", str(state), "--phase", "apply",
                        ], capture_output=True, text=True)
                        assert result.returncode != 0, "conflicting canonical trust accepted"
                        assert "declare different decisions" in result.stderr, result.stderr
                        assert trust_path.read_bytes() == before
                        trust_input.write_text(json.dumps(trust))
                    snapshot = state.read_bytes()
                    backup_count = len(list(state.parent.glob("*.bak")))
                    activate("plain")
                    assert state.read_bytes() == snapshot and len(list(state.parent.glob("*.bak"))) == backup_count
                    activate("empty")
                    if backend == "hm":
                        assert "redaction" not in json.loads(config_path.read_text())
                        assert "hideThinkingBlock" not in json.loads((harness / "settings.json").read_text())
                    activate("disabled")
                    if backend == "hm":
                        assert json.loads(config_path.read_text()) == {"native": "keep"}
                        assert json.loads((harness / "settings.json").read_text()) == {"native": "keep"}
                elif backend == "hm":
                    phase("secret", "prune")
                    assert not config_path.exists()
                    (root / "git-token").write_text("test-token")
                    activate("secret")
                    assert json.loads(config_path.read_text())["gitTokens"] == {"github.com": "test-token"}
                    assert not any(b"test-token" in path.read_bytes() for path in state.parent.glob("*.bak"))
                    for failure in ("missing", "empty", "helper"):
                        (root / "git-token").unlink(missing_ok=True)
                        if failure == "empty":
                            (root / "git-token").touch()
                        helper = root / "failed-helper"
                        helper.write_text(f'#!{data["bash"]}\nset -euETo pipefail\nshopt -s inherit_errexit 2>/dev/null || :\nprintf partial-secret\nfalse\n')
                        helper.chmod(0o755)
                        name = "helper" if failure == "helper" else "secret"
                        phase(name, "prune")
                        before = config_path.read_bytes(), state.read_bytes()
                        try:
                            phase(name, "apply")
                        except subprocess.CalledProcessError:
                            pass
                        else:
                            raise AssertionError(f"{failure} token renderer succeeded")
                        assert (config_path.read_bytes(), state.read_bytes()) == before
                    assert b"test-token" not in state.read_bytes()
                    activate("disabled")
                    assert not config_path.exists()
                else:
                    phase("run", "prune")
                    assert not config_path.exists()
                    (root / "provider-data").write_text('{"provider":true}')
                    activate("run")
                    assert json.loads(config_path.read_text()) == {"provider": True}
                    activate("disabled")
                    assert not config_path.exists()
                print(f"PASS: {backend}, prefix={index}, {scenario}: disk, state, modes, restore, retire, legacy, renderers")
