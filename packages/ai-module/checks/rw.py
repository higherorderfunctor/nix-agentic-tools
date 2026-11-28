"""Execute document merge cases for every files codec."""

import hashlib
import importlib.util
import json
from pathlib import Path
import stat
import sys
import tempfile
import tomllib

import yaml

spec = importlib.util.spec_from_file_location("files_engine", sys.argv[1])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
decoders = {"json": json.loads, "toml": tomllib.loads, "yaml": yaml.safe_load}
assert set(engine.codecs.FORMATS) == set(decoders), "each engine codec needs an independent decoder"
formats = tuple(decoders)
# Ledger digests are SHA-256 of the canonical typed value, not the file's bytes.
ONE_VALUE_DIGEST = "9a1072cf2c6fcb2de59fd47e2b94af145ddfc9d92d9dc1b0b628116733edcadd"
CONFIGURED_VALUE_DIGEST = "4d11a8a4082d3438e51437e3f44bbb861802610588dc7ead3677beb561ed4f73"


def plan(format_name, value, method="rw"):
    return [{"path": "nested/settings", "content": {"text": engine.codecs.serialize(format_name, value).decode()}, "format": format_name,
             "method": method, "mode": None, "executable": None, "recursive": False}]


def value_plan(format_name, value, directory):
    rendered = directory / f"value.{format_name}"
    rendered.write_bytes(engine.codecs.serialize(format_name, value))
    result = plan(format_name, value)
    result[0]["content"] = {"rendered": str(rendered), "value": value}
    return result


def state_data(path):
    return json.loads(path.read_text())


def run(config, root, state, phase="apply"):
    engine.reconcile(config, root, state, phase)


def document(path, format_name):
    return decoders[format_name](path.read_text())


for format_name in formats:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "root"
        root.mkdir()
        state = Path(temporary) / "state" / "runtime.json"
        target = root / "nested/settings"
        initial = plan(format_name, {"nested": {"owned": "one"}})
        run(initial, root, state)
        assert document(target, format_name) == {"nested": {"owned": "one"}}
        assert state_data(state)["files"]["nested/settings"]["keys"] == {"/nested/owned": ONE_VALUE_DIGEST}
        native = {"nested": {"owned": "one", "native": "keep"}, "sibling": 3}
        target.write_bytes(engine.codecs.serialize(format_name, native))
        run(initial, root, state)
        assert document(target, format_name) == native
        assert list(state.parent.glob("*.bak")) == []
        changed = plan(format_name, {"nested": {"owned": "two", "claimed": "configured"}})
        target.write_bytes(engine.codecs.serialize(format_name, {"nested": {**native["nested"], "claimed": "configured"}, "sibling": 3}))
        run(changed, root, state)
        assert len(list(state.parent.glob("*.bak"))) == 1
        target.write_bytes(engine.codecs.serialize(format_name, {"nested": {**native["nested"], "claimed": "local"}, "sibling": 3}))
        run(changed, root, state)
        assert document(target, format_name) == {"nested": {"owned": "two", "claimed": "configured", "native": "keep"}, "sibling": 3}
        assert len(list(state.parent.glob("*.bak"))) == 2
        retired = plan(format_name, {"nested": {"claimed": "configured"}})
        run(retired, root, state)
        assert document(target, format_name) == {"nested": {"claimed": "configured", "native": "keep"}, "sibling": 3}
        assert state_data(state)["files"]["nested/settings"]["keys"] == {"/nested/claimed": CONFIGURED_VALUE_DIGEST}
        conflict = plan(format_name, {"nested": "scalar"})
        before_bytes = target.read_bytes()
        try:
            run(conflict, root, state)
        except ValueError as error:
            assert str(error) == "map-to-scalar conflict: nested/settings /nested"
        else:
            raise AssertionError("native descendant erased")
        assert target.read_bytes() == before_bytes
        run([], root, state, "prune")
        assert document(target, format_name) == {"nested": {"native": "keep"}, "sibling": 3}
        assert not state.exists()
        broken = b"[not valid\n" if format_name == "toml" else b"{broken"
        target.write_bytes(broken)
        try:
            run(initial, root, state)
        except ValueError as error:
            assert str(error).startswith(f"malformed {format_name} document: nested/settings:"), error
        else:
            raise AssertionError(f"malformed {format_name} accepted")
        assert target.read_bytes() == broken and not state.exists()
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "root"
        root.mkdir()
        state = Path(temporary) / "state" / "runtime.json"
        target = root / "nested/settings"
        run(plan(format_name, {"one": 1}), root, state)
        run([], root, state, "prune")
        assert not target.exists() and not state.exists()
        target.parent.mkdir(exist_ok=True)
        target.write_bytes(engine.codecs.serialize(format_name, {"one": 1}))
        run(plan(format_name, {"one": 1}), root, state)
        assert state_data(state)["files"]["nested/settings"]["created"] is False
        run([], root, state, "prune")
        assert target.exists() and document(target, format_name) == {}
        assert list(state.parent.glob("*.bak")) == []
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "root"
        root.mkdir()
        state = Path(temporary) / "state" / "runtime.json"
        target = root / "nested/settings"
        initial = plan(format_name, {"owned": 1})
        run(initial, root, state)
        target.write_bytes(engine.codecs.serialize(format_name, {"owned": 1, "native": {}}))
        run([], root, state, "prune")
        assert document(target, format_name) == {"native": {}}
        assert not state.exists()
        assert len(list(state.parent.glob("*.bak"))) == 1
        target.unlink()
        run(initial, root, state)
        before_bytes = engine.codecs.serialize(format_name, {"owned": 1, "native": {}})
        target.write_bytes(before_bytes)
        before_state = state.read_bytes()
        try:
            run(plan(format_name, {"owned": 1}, "ro"), root, state, "prune")
        except ValueError as error:
            assert "prevent takeover" in str(error)
        else:
            raise AssertionError("native empty map allowed takeover")
        assert target.read_bytes() == before_bytes and state.read_bytes() == before_state
        target.write_bytes(engine.codecs.serialize(format_name, {"owned": {}}))
        before_bytes = target.read_bytes()
        try:
            run(plan(format_name, {"owned": 2}), root, state)
        except ValueError as error:
            assert str(error) == "map-to-scalar conflict: nested/settings /owned"
        else:
            raise AssertionError("native empty map replaced by scalar")
        assert target.read_bytes() == before_bytes and state.read_bytes() == before_state
        run([], root, state, "prune")
        assert document(target, format_name) == {"owned": {}}
        assert not state.exists()
    print(f"PASS: {format_name} keys, native data, backup, retirement, malformed input, adoption")

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary) / "root"
    root.mkdir()
    state = Path(temporary) / "state" / "runtime.json"
    target = root / "nested/settings"
    run(plan("json", {"owned": 1, "native": 2}, "ro"), root, state)
    run(plan("json", {"owned": 1}), root, state)
    assert document(target, "json") == {"owned": 1, "native": 2}
    assert stat.S_IMODE(target.stat().st_mode) == 0o600
    assert state_data(state)["files"]["nested/settings"]["created"] is True
    run(plan("toml", {"owned": 3}), root, state)
    assert document(target, "toml") == {"owned": 3, "native": 2}
    assert list(state.parent.glob("*.bak")) == []
print("PASS: ro to rw transfer and JSON to TOML conversion")

for executable, expected_mode in ((None, 0o600), (True, 0o711)):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "root"
        root.mkdir()
        state = Path(temporary) / "state" / "runtime.json"
        target = root / "nested/settings"
        old = plan("json", {"owned": 1}, "ro")
        old[0]["executable"] = executable
        run(old, root, state)
        target.unlink()
        wanted = plan("json", {"owned": 1})
        run(wanted, root, state, "prune")
        assert not target.exists() and state_data(state)["files"]["nested/settings"]["method"] == "ro"
        run(wanted, root, state)
        assert document(target, "json") == {"owned": 1}
        assert stat.S_IMODE(target.stat().st_mode) == expected_mode
        assert state_data(state)["files"]["nested/settings"]["method"] == "rw"
print("PASS: missing ro destination transfers to rw in prune and apply")

for native in (False, True):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "root"
        root.mkdir()
        state = Path(temporary) / "state" / "runtime.json"
        target = root / "nested/settings"
        run(plan("json", {"owned": 1}), root, state)
        if native:
            target.write_bytes(engine.codecs.serialize("json", {"owned": 1, "native": 2}))
        target.chmod(0o644)
        original = target.read_bytes()
        requested = plan("json", {"owned": 1})
        requested[0]["mode"] = "0600"
        run(requested, root, state)
        assert list(state.parent.glob("*.bak")) == []
        assert target.read_bytes() == original
        assert stat.S_IMODE(target.stat().st_mode) == 0o600
        assert state_data(state)["files"]["nested/settings"]["mode"] == 0o600
print("PASS: external permission change reset to the explicit mode without a backup")

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary) / "root"
    root.mkdir()
    state = Path(temporary) / "state" / "runtime.json"
    target = root / "nested/settings"
    wanted = plan("json", {"owned": 1}, "ro")
    desired = engine.codecs.serialize("json", {"owned": 1})
    # A git checkout of a committed copy: the desired bytes at 0644, unowned.
    target.parent.mkdir()
    target.write_bytes(desired)
    target.chmod(0o644)
    run(wanted, root, state)
    assert list(state.parent.glob("*.bak")) == []
    assert target.read_bytes() == desired and stat.S_IMODE(target.stat().st_mode) == 0o444
    recorded = state_data(state)["files"]["nested/settings"]
    assert (recorded["digest"], recorded["mode"], recorded["created"]) == (hashlib.sha256(desired).hexdigest(), 0o444, False)
    # The same bytes behind a symlink are another type: refused, kept as is.
    source = Path(temporary) / "same-bytes"
    source.write_bytes(desired)
    target.unlink()
    target.symlink_to(source)
    try:
        run(wanted, root, state)
    except ValueError as error:
        assert "non-regular destination refused" in str(error)
    else:
        raise AssertionError("symlink with identical bytes adopted")
    assert target.is_symlink() and list(state.parent.glob("*.bak")) == []
    # Different bytes at a different mode still back up the full image.
    target.unlink()
    target.write_bytes(b'{ "owned" : 1 }\n')
    target.chmod(0o644)
    run(wanted, root, state)
    backups = list(state.parent.glob("*.bak"))
    assert len(backups) == 1 and backups[0].read_bytes() == b'{ "owned" : 1 }\n'
    assert stat.S_IMODE(backups[0].stat().st_mode) == 0o644
    assert target.read_bytes() == desired and stat.S_IMODE(target.stat().st_mode) == 0o444
print("PASS: permission-only drift resets the mode; type or byte drift does not")

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary) / "root"
    root.mkdir()
    state = Path(temporary) / "state" / "runtime.json"
    source = Path(temporary) / "source.json"
    source.write_bytes(engine.codecs.serialize("json", {"owned": 1}))
    source.chmod(0o755)
    wanted = plan("json", {"owned": 1})
    wanted[0]["content"] = {"source": str(source)}
    target = root / "nested/settings"
    run(wanted, root, state)
    assert stat.S_IMODE(target.stat().st_mode) == 0o711
    target.chmod(0o740)
    run(wanted, root, state)
    assert stat.S_IMODE(target.stat().st_mode) == 0o740
    assert list(state.parent.glob("*.bak")) == []
print("PASS: executable source bits and existing rw permissions preserved")

mutation_cases = (
    ("ro-create", None, plan("json", {"owned": 2}, "ro"), "apply"),
    ("ro-delete", plan("json", {"owned": 1}, "ro"), [], "prune"),
    ("ro-mode", plan("json", {"owned": 1}, "ro"), plan("json", {"owned": 1}, "ro"), "apply"),
    ("ro-replace", plan("json", {"owned": 1}, "ro"), plan("json", {"owned": 2}, "ro"), "apply"),
    ("rw-create", None, plan("json", {"owned": 2}), "apply"),
    ("rw-delete", plan("json", {"owned": 1}), [], "prune"),
    ("rw-format", plan("json", {"owned": 1}), plan("toml", {"owned": 1}), "apply"),
    ("rw-mode", plan("json", {"owned": 1}), plan("json", {"owned": 1}), "apply"),
    ("rw-replace", plan("json", {"owned": 1}), plan("json", {"owned": 2}), "apply"),
)
# Divergences whose desired bytes equal the file's; an unchanged rw key keeps
# the local formatting, so rw-mode's "bytes" case differs in mode only.
UNCHANGED_BYTES_MODES = {
    ("ro-mode", "mode"): 0o400,
    ("rw-create", "mode"): 0o600,
    ("rw-mode", "bytes"): 0o400,
    ("rw-mode", "mode"): 0o400,
}
for name, initial, wanted, phase in mutation_cases:
    if name == "ro-create":
        divergences = ("bytes",)
    elif name == "ro-mode":
        divergences = ("mode",)
    else:
        divergences = ("bytes", "mode")
    for divergence in divergences:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "root"
            root.mkdir()
            state = Path(temporary) / "state" / "runtime.json"
            target = root / "nested/settings"
            if initial:
                run(initial, root, state)
            else:
                target.parent.mkdir()
                target.write_bytes(engine.codecs.serialize("json", {"owned": 1 if divergence == "bytes" else 2}))
                target.chmod(0o444 if name.startswith("ro") else 0o600)
            if divergence == "bytes":
                target.chmod(0o644)
                target.write_bytes(b'{ "owned" : 1 }\n')
                target.chmod(0o444 if name.startswith("ro") else 0o600)
            else:
                target.chmod(0o644)
            if name.endswith("mode") or (initial is None and divergence == "mode" and name.startswith("rw")):
                wanted[0]["mode"] = "0400" if name.endswith("mode") else "0600"
            before = target.read_bytes(), stat.S_IMODE(target.stat().st_mode)
            run(wanted, root, state, phase)
            backups = list(state.parent.glob("*.bak"))
            if (name, divergence) in UNCHANGED_BYTES_MODES:
                # Only permission bits differ from the desired image.
                assert backups == [], (name, backups)
                assert target.read_bytes() == before[0]
                assert stat.S_IMODE(target.stat().st_mode) == UNCHANGED_BYTES_MODES[name, divergence]
                continue
            assert len(backups) == 1, (name, divergence, backups)
            assert backups[0].read_bytes() == before[0]
            assert stat.S_IMODE(backups[0].stat().st_mode) == before[1]
            assert target.exists() == (not name.endswith("delete"))
print("PASS: full-image backups for create, replace, delete, format, and mode mutations unless only permissions differ")

with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary) / "root"
    root.mkdir()
    state = Path(temporary) / "state" / "runtime.json"
    target = root / "nested/settings"
    wanted = plan("json", {"owned": 1})
    run(wanted, root, state)
    target.write_bytes(b'{ "owned" : 1 }\n')
    before = target.read_bytes()
    run(wanted, root, state)
    assert target.read_bytes() == before and list(state.parent.glob("*.bak")) == []
print("PASS: unchanged JSON keys retain local whitespace")

# With these rows and the generated JSON to TOML and TOML to YAML
# transitions, each codec reads and writes a converted document.
for source_format, target_format in (("toml", "json"), ("yaml", "json")):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "root"
        root.mkdir()
        state = Path(temporary) / "state" / "runtime.json"
        target = root / "nested/settings"
        run(value_plan(source_format, {"owned": 1}, Path(temporary)), root, state)
        target.write_bytes(engine.codecs.serialize(source_format, {"owned": 1, "native": 2}))
        run(value_plan(target_format, {"owned": 1}, Path(temporary)), root, state)
        assert document(target, target_format) == {"owned": 1, "native": 2}
        assert state_data(state)["files"]["nested/settings"]["format"] == target_format
    print(f"PASS: {source_format} to {target_format} rw switch preserves native keys")

for format_name in formats:
    methods = ("ro", "symlink") if format_name == "json" else ("ro",)
    for method in methods:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "root"
            root.mkdir()
            state = Path(temporary) / "state" / "runtime.json"
            target = root / "nested/settings"
            run(plan(format_name, {"owned": 1}), root, state)
            wanted = plan(format_name, {"new": 2}, method)
            target.write_bytes(engine.codecs.serialize(format_name, {"owned": 1, "native": 2}))
            before = target.read_bytes(), state.read_bytes()
            try:
                run(wanted, root, state, "prune")
            except ValueError as error:
                assert "prevent takeover" in str(error)
            else:
                raise AssertionError("native keys allowed takeover")
            assert (target.read_bytes(), state.read_bytes()) == before
            if method == "ro":
                target.write_bytes(engine.codecs.serialize(format_name, {"owned": 1}))
                run(wanted, root, state, "prune")
                assert not target.exists() and not state.exists()
                run(wanted, root, state)
                assert document(target, format_name) == {"new": 2}
                assert state_data(state)["files"]["nested/settings"]["method"] == "ro"
print("PASS: rw switch-away retirement to ro for every codec; native JSON keys block a symlink takeover")

for format_name, commented in (("json", b'// keep\n{"owned": 1}\n'),
                               ("toml", b'# keep\nowned = 1\n')):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "root"
        root.mkdir()
        state = Path(temporary) / "state" / "runtime.json"
        target = root / "nested/settings"
        run(plan(format_name, {"owned": 1}), root, state)
        target.write_bytes(commented)
        run(plan(format_name, {"owned": 2}), root, state)
        assert target.read_bytes().startswith(commented.splitlines()[0])
        other = next(name for name in formats if name != format_name)
        before = target.read_bytes(), state.read_bytes()
        try:
            run(plan(other, {"owned": 3}), root, state)
        except ValueError as error:
            assert "comment-preserving format switch refused" in str(error)
        else:
            raise AssertionError("commented format switch accepted")
        assert (target.read_bytes(), state.read_bytes()) == before
        run([], root, state, "prune")
        assert target.exists() and target.read_bytes().startswith(commented.splitlines()[0])
print("PASS: JSON and TOML comments survive merge and retirement; conversion refuses loss")

for operation in ("update", "retire"):
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "root"
        root.mkdir()
        state = Path(temporary) / "state" / "runtime.json"
        target = root / "nested/settings"
        run(plan("yaml", {"owned": {"key": 1}}), root, state)
        target.write_bytes(b"owned: &shared\n  key: 1\nnative: *shared\n")
        before = target.read_bytes(), state.read_bytes()
        try:
            run(plan("yaml", {"owned": {"key": 2}}) if operation == "update" else [],
                root, state, "apply" if operation == "update" else "prune")
        except ValueError as error:
            assert "nested/settings" in str(error) and "aliases and anchors" in str(error)
        else:
            raise AssertionError(f"YAML alias {operation} accepted")
        assert (target.read_bytes(), state.read_bytes()) == before
print("PASS: YAML aliases refuse update and retirement before mutation")

if len(sys.argv) > 2:
    value_plans = json.loads(Path(sys.argv[2]).read_text())
    for format_name in formats:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "root"
            root.mkdir()
            state = Path(temporary) / "state" / "runtime.json"
            item, = value_plans[format_name]
            # Distinguish reading the rendered store file from serializing the
            # inline value again: the engine must merge the rendered bytes.
            item["content"]["value"] = {"owned": 99}
            run([item], root, state)
            assert document(root / "nested/settings", format_name) == {"owned": 1}
    print("PASS: normalized value plans use pinned JSON, TOML and YAML rendering")
