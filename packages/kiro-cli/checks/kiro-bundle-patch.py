"""Check exact matching, byte preservation, and fail-open launch warnings."""

import fcntl
import importlib.util
import itertools
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

PATCHER = sys.argv.pop(1)
spec = importlib.util.spec_from_file_location("patcher", PATCHER)
patcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(patcher)
LAUNCHERS = json.loads(Path(sys.argv.pop(1)).read_text())
IDENTITY = b"Custom identity. Another sentence!"
BUNDLE = (b"function identity(){return `" + patcher.IDENTITY_SENTENCE
          + b" Terminal guidance.`}\nvar steering='Before\\n\\n"
          + patcher.WORKTREE_PARAGRAPH + b"After';\nvar workflow='"
          + patcher.FILE_CHECK_PARAGRAPH + b"';\n")


def prepare_bundle(root, data):
    bundle = root / "data/kas/1.0.0-probe/node_modules/@kiro/agent/dist/server/acp-server.js"
    bundle.parent.mkdir(parents=True)
    sibling = root / "data/kas/1.0.0-probe/node_modules/vendor/probe.txt"
    sibling.parent.mkdir()
    sibling.write_text("sibling")
    bundle.write_bytes(data)
    env = os.environ | {"HOME": str(root), "XDG_CACHE_HOME": str(root / "cache"), "KIRO_DATA_DIR": str(root / "data")}
    env.pop("KIRO_KAS_SERVER_PATH", None)
    return bundle, env


class PatchTests(unittest.TestCase):
    def test_selected_patches_preserve_other_bytes_and_execute(self):
        subsets = [names for r in range(len(patcher.FIXED) + 1) for names in itertools.combinations(patcher.FIXED, r)]
        for identity, names in itertools.product((IDENTITY, None), subsets):
            if identity is None and not names:
                continue
            strip = "stripVendorWorktreeSteering" in names
            relative = "relativeFileCheckPaths" in names
            with self.subTest(identity=identity, names=names):
                result, errors = patcher.patch(BUNDLE, patcher.replacements(identity, names))
                self.assertEqual(errors, [])
                expected = BUNDLE
                if identity is not None:
                    expected = expected.replace(patcher.IDENTITY_SENTENCE, identity)
                for name in names:
                    expected = expected.replace(*patcher.FIXED[name])
                self.assertEqual(result, expected)
                output = subprocess.check_output([
                    "node", "-e", result.decode() + "console.log(identity());console.log(steering);console.log(workflow);"
                ])
                self.assertIn((identity or patcher.IDENTITY_SENTENCE) + b" Terminal guidance.", output)
                self.assertIn(b"After", output)
                self.assertEqual(b"workflow owns the worktree setup" in output, not strip)
                # The stop-condition file is written and checked at one path.
                self.assertEqual(b"at the same relative path" in output, relative)
                self.assertEqual(b"stop condition is absolute" in output, not relative)

    def test_default_selects_no_replacement(self):
        self.assertEqual(patcher.replacements(), [])

    def test_drift_skips_only_the_affected_replacement(self):
        selected = patcher.replacements(IDENTITY, patcher.FIXED)
        for name, source, _ in selected:
            for data, count in ((BUNDLE.replace(source, b"changed"), 0), (BUNDLE + source, 2)):
                with self.subTest(name=name, count=count):
                    result, errors = patcher.patch(data, selected)
                    self.assertEqual(errors, [f"{name}: expected exact source text once, found {count}; bundle drift"])
                    healthy = [(n, s, r) for n, s, r in selected if n != name]
                    self.assertEqual(result, patcher.patch(data, healthy)[0])
                    self.assertNotEqual(result, data)
        result, errors = patcher.patch(b"all changed", selected)
        self.assertIsNone(result)
        self.assertEqual(len(errors), len(selected))

    def test_check_fails_closed_for_each_source(self):
        selected = patcher.replacements(IDENTITY, patcher.FIXED)
        for name, source, _ in selected:
            for count in (0, 1, 2):
                with self.subTest(name=name, count=count), tempfile.TemporaryDirectory() as tmp:
                    path = Path(tmp) / "bundle.js"
                    data = BUNDLE.replace(source, b"changed") if count == 0 else BUNDLE + source if count == 2 else BUNDLE
                    path.write_bytes(data)
                    result = subprocess.run([sys.executable, PATCHER, str(path), "--check"], capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0 if count == 1 else 1, result.stderr)
                    if count != 1:
                        self.assertIn(f"FAIL: kiro-bundle-patch: {name}: expected exact source text once, found {count}", result.stderr)

    def test_invalid_identity_is_rejected(self):
        for identity in (b"", b"no punctuation", b"Bad `identity`.", b"Bad ${identity}."):
            with self.subTest(identity=identity), self.assertRaisesRegex(ValueError, "identity:"):
                patcher.replacements(identity)

    def test_materializer_and_both_launch_entry_points(self):
        for mode, launchers in LAUNCHERS.items():
            identity = launchers["identity"] and launchers["identity"].encode()
            selected = patcher.replacements(identity, launchers["replace"])
            for name, source, _ in selected:
                for count in (0, 1, 2):
                    with self.subTest(mode=mode, name=name, count=count), tempfile.TemporaryDirectory() as tmp:
                        root = Path(tmp)
                        data = BUNDLE.replace(source, b"changed") if count == 0 else BUNDLE + source if count == 2 else BUNDLE
                        bundle, env = prepare_bundle(root, data)
                        result = subprocess.run([launchers["materializer"]], env=env, capture_output=True, text=True)
                        expected, errors = patcher.patch(data, selected)
                        self.assertEqual(result.returncode, 0 if expected is not None else 1, result.stderr)
                        warnings = "".join(f"WARNING: kiro-bundle-patch: {error}; replacement skipped\n" for error in errors)
                        self.assertEqual(result.stderr, warnings)
                        if expected is not None:
                            patched = Path(result.stdout)
                            self.assertEqual(patched.read_bytes(), expected)
                            self.assertEqual((patched.parents[4] / "vendor/probe.txt").read_text(), "sibling")
                            # A cached partial patch still names its skipped replacement.
                            repeat = subprocess.run([launchers["materializer"]], env=env, capture_output=True, text=True)
                            self.assertEqual((repeat.returncode, repeat.stdout, repeat.stderr), (0, result.stdout, warnings))
                        else:
                            self.assertEqual(result.stdout, "")
                            self.assertEqual(list(root.rglob(".ready")), [])
                        # Managed success replaces an inherited override; failure
                        # must clear it through either supported entry point.
                        env["KIRO_KAS_SERVER_PATH"] = "/parent-cache/patched/acp-server.js"
                        for binary in ("kiro-cli", "kiro-cli-chat"):
                            launched = subprocess.run([f"{launchers['wrapper']}/bin/{binary}"], env=env, capture_output=True, text=True)
                            self.assertEqual(launched.returncode, 0, launched.stderr)
                            if expected is not None:
                                self.assertEqual(launched.stdout, f"launched:{result.stdout}\n")
                            else:
                                self.assertEqual(launched.stdout, "launched:stock\n")
                                self.assertIn(f"WARNING: kiro-bundle-patch: {name}:", launched.stderr)
                        self.assertEqual(bundle.read_bytes(), data)


    def test_concurrent_cold_launches_recheck_readiness_under_lock(self):
        for mode, launchers in LAUNCHERS.items():
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                _, env = prepare_bundle(root, BUNDLE)
                server = Path(subprocess.check_output([launchers["materializer"]], env=env, text=True))
                out = server.parents[5]
                staged = root / "staged"
                out.rename(staged)
                expected = (staged / server.relative_to(out)).read_bytes()
                inode = (staged / server.relative_to(out)).stat().st_ino
                processes = []
                # Act as a publisher holding the shared lock. Both cold launches
                # must wait; publish before releasing it to force the readiness
                # recheck, rather than relying on scheduler luck to expose a race.
                with Path(str(out) + ".lock").open("w") as lock:
                    fcntl.flock(lock, fcntl.LOCK_EX)
                    try:
                        for binary in ("kiro-cli", "kiro-cli-chat"):
                            processes.append(subprocess.Popen(
                                [f"{launchers['wrapper']}/bin/{binary}"],
                                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                            ))
                        for process in processes:
                            with self.assertRaises(subprocess.TimeoutExpired):
                                process.communicate(timeout=0.5)
                        self.assertFalse(out.exists())
                        staged.rename(out)
                    finally:
                        fcntl.flock(lock, fcntl.LOCK_UN)
                        for process in processes:
                            try:
                                stdout, stderr = process.communicate(timeout=10)
                            except subprocess.TimeoutExpired:
                                process.kill()
                                process.communicate()
                                raise
                            self.assertEqual(process.returncode, 0, stderr)
                            self.assertEqual(stdout, f"launched:{server}\n")
                            self.assertEqual(server.read_bytes(), expected)
                            self.assertEqual(server.stat().st_ino, inode)
                            self.assertEqual((server.parents[4] / "vendor/probe.txt").read_text(), "sibling")


if __name__ == "__main__":
    unittest.main()
