"""S2 behavior oracles fixed before the syntax driver exists."""

import hashlib
import importlib.util
import json
import os
import re
import shlex
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

OWNER = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("s2_abi", OWNER / "schema/abi.py")
abi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(abi)
LIMIT = 1048576
preflight_spec = importlib.util.spec_from_file_location("s2_preflight", OWNER / "checks/fixtures/bootstrap/test-preflight.py")
preflight = importlib.util.module_from_spec(preflight_spec)
preflight_spec.loader.exec_module(preflight)


def identity(namespace, *parts):
    # Independent transcription of F1's length-delimited UTF-8 framing.
    return "nixql:v1:" + namespace + ":" + "".join(
        str(len(part.encode("utf-8"))) + ":" + part for part in parts)


def sha(data):
    return hashlib.sha256(data).hexdigest()


class DriverTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="s2-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.driver = os.environ["NIXQL_SYNTAX_DRIVER"]

    def run_files(self, files, *, logical="project", content="snapshot-v1", mutate=None, folder="root"):
        root = self.base / folder
        root.mkdir(parents=True, exist_ok=True)
        entries = []
        for name, data in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            entries.append({"contentHash": sha(data), "path": name})
        manifest = {"roots": [{"files": entries, "logicalName": logical,
            "path": str(root), "rootContentIdentity": content, "sourceKind": "project"}]}
        if mutate:
            mutate(root, manifest)
        manifest_path = self.base / (folder + "-manifest.json")
        manifest_path.write_text(json.dumps(manifest))
        output = self.base / (folder + "-output")
        environment = {key: value for key, value in os.environ.items()
            if not key.startswith("CODEQL_EXTRACTOR_NIX_")}
        result = subprocess.run([self.driver, str(manifest_path), str(output)],
            capture_output=True, timeout=120, env=environment)
        self.assertLess(len(result.stderr), 8192, "unbounded diagnostic")
        envelope = json.loads((output / "facts.json").read_text())
        self.assertEqual(envelope["protocolVersion"], 1)
        rows = envelope["facts"]
        abi.validate(rows)
        self.assertTrue(rows, "empty extraction cannot pass")
        return result, rows, output, root

    def table(self, rows, name):
        return [arguments for relation, arguments in rows if relation == name]

    def accepted(self, result, rows):
        self.assertEqual(result.returncode, 0, result.stderr[:2048])
        self.assertTrue(self.table(rows, "nx_files"))
        self.assertTrue(self.table(rows, "nx_anchors"))
        self.assertTrue(self.table(rows, "nx_syntax_results"))

    def test_file_anchor_keys_archive_and_structural_collisions(self):
        data = b"41"
        result, rows, output, root = self.run_files({"one.nix": data, "two.nix": data})
        self.accepted(result, rows)
        root_key = identity("root", "project", "snapshot-v1")
        files = self.table(rows, "nx_files")
        self.assertEqual({tuple(row) for row in files}, {
            (identity("file", root_key, name, sha(data)), root_key, name, sha(data), "project")
            for name in ("one.nix", "two.nix")})
        anchors = self.table(rows, "nx_anchors")
        self.assertEqual(len({row[0] for row in anchors}), len(anchors))
        for key, file, start, end, kind, path in anchors:
            self.assertEqual(key, identity("anchor", file, str(start), str(end), kind, path))
            self.assertEqual(json.dumps(json.loads(path), separators=(",", ":")), path)
            self.assertTrue(all(type(index) is int and index >= 0 for index in json.loads(path)))
            self.assertLessEqual(0, start)
            self.assertLessEqual(start, end)
            self.assertLessEqual(end, len(data))
        for file, *_ in files:
            same_span = {(row[4], row[5]) for row in anchors if row[1:4] == [file, 0, 2]}
            self.assertIn(("source_code", "[]"), same_span)
            self.assertIn(("integer_expression", "[0]"), same_span)
        for name in ("one.nix", "two.nix"):
            self.assertEqual((output / "archive" / str(root / name).lstrip("/")).read_bytes(), data)
        self.assertEqual({row[1] for row in self.table(rows, "nx_syntax_results")}, {"complete"})

    def test_content_path_and_root_changes_have_distinct_ids(self):
        runs = [self.run_files({name: data}, logical=logical, content=content, folder=folder)
            for folder, name, data, logical, content in [
                ("a", "x.nix", b"41", "project", "snapshot-v1"),
                ("edited", "x.nix", b"42", "project", "snapshot-v1"),
                ("renamed", "y.nix", b"41", "project", "snapshot-v1"),
                ("root-name", "x.nix", b"41", "dependency", "snapshot-v1"),
                ("root-content", "x.nix", b"41", "project", "snapshot-v2")]]
        for result, rows, *_ in runs:
            self.accepted(result, rows)
        ids = [self.table(rows, "nx_files")[0][0] for _, rows, *_ in runs]
        self.assertEqual(len(set(ids)), 5)

    def test_unicode_crlf_comments_interpolation_paths_and_recovery(self):
        sources = {
            "coordinates.nix": (OWNER / "ql/test/anchors/coordinates.nix.in").read_bytes(),
            "features.nix": '# café\n{ path = ./a/b; text = "é${toString 41}"; }\n'.encode(),
            "recovered.nix": b"{\n broken = ;\n okay = 41;\n}\n",
            "empty.nix": b"",
        }
        result, rows, output, root = self.run_files(sources)
        self.accepted(result, rows)
        files = {row[2]: row[0] for row in self.table(rows, "nx_files")}
        states = {row[0]: row[1:] for row in self.table(rows, "nx_syntax_results")}
        self.assertEqual(states[files["recovered.nix"]][0], "recovered")
        self.assertGreater(states[files["recovered.nix"]][1], 0)
        for name in ("coordinates.nix", "features.nix"):
            self.assertEqual(states[files[name]], ["complete", 0])
        self.assertIn(states[files["empty.nix"]][0], ("complete", "recovered"))
        anchors = self.table(rows, "nx_anchors")
        for name, data in sources.items():
            self.assertEqual((output / "archive" / str(root / name).lstrip("/")).read_bytes(), data)
            for row in anchors:
                if row[1] == files[name]:
                    self.assertLessEqual(0, row[2])
                    self.assertLessEqual(row[2], row[3])
                    self.assertLessEqual(row[3], len(data))
        self.assertTrue(any(row[1:4] == [files["empty.nix"], 0, 0] for row in anchors))
        for name, token in (("coordinates.nix", b"73"), ("coordinates.nix", b"97"),
                            ("features.nix", "# café".encode()), ("features.nix", b"./a/b"),
                            ("features.nix", b"${toString 41}"), ("features.nix", b"41"),
                            ("recovered.nix", b"41")):
            start = sources[name].index(token)
            self.assertTrue(any(row[1:4] == [files[name], start, start + len(token)] for row in anchors),
                (name, token, "lexical syntax span absent from byte-accurate anchors"))

    def assert_refused_transaction(self, result, rows, output, name, code):
        self.assertNotEqual(result.returncode, 0)
        files = {row[2]: row[0] for row in self.table(rows, "nx_files")}
        states = {row[0]: row[1] for row in self.table(rows, "nx_syntax_results")}
        self.assertEqual(states[files["c.nix"]], "complete")
        self.assertTrue(any(row[1] == files["c.nix"] for row in self.table(rows, "nx_anchors")))
        if name in files:
            self.assertEqual(states[files[name]], "failed")
            self.assertFalse(any(row[1] == files[name] for row in self.table(rows, "nx_anchors")))
        self.assertIn(code, [row[2] for row in self.table(rows, "nx_diagnostics")])
        self.assertEqual(len(list((output / "trap").glob("syntax-*.trap"))), 1,
            "refused file published a raw transaction")
        self.assertFalse(list((output / "archive").rglob(name)))
        self.assertEqual(len(list((output / "archive").rglob("c.nix"))), 1)

    def test_stale_manifest_refuses_file_and_preserves_completed_control(self):
        def mutate(root, _):
            (root / "raced.nix").write_bytes(b"99")
        result, rows, output, _ = self.run_files({"c.nix": b"41", "raced.nix": b"42"}, mutate=mutate)
        self.assert_refused_transaction(result, rows, output, "raced.nix", "source-snapshot-race")

    def test_snapshot_race_refuses_file_and_preserves_completed_control(self):
        original_driver = Path(self.driver).read_text()
        binaries = re.findall(r"/[^\s]+/bin/nixql-anchors", original_driver)
        self.assertEqual(len(binaries), 1, "installed launcher must name one real extractor")
        for mode in ("bytes", "retarget"):
            with self.subTest(mode=mode):
                marker = self.base / (mode + "-mutation")
                wrapper = self.base / (mode + "-extractor")
                # The real extractor finishes from accepted snapshot bytes before
                # this wrapper changes the checkout. No timing/polling race.
                wrapper.write_text(f"#!{sys.executable}\n" +
                    "import pathlib, subprocess, sys\n" +
                    f"result = subprocess.run([{binaries[0]!r}, *sys.argv[1:]])\n" +
                    "source = pathlib.Path(sys.argv[2])\n" +
                    "if source.name == 'raced.nix':\n" +
                    "    assert result.returncode == 0\n" +
                    "    assert pathlib.Path(sys.argv[1]).read_bytes() == source.read_bytes() == b'42'\n" +
                    ("    source.write_bytes(b'99')\n" if mode == "bytes" else
                     "    alternate = source.with_name('alternate.nix')\n"
                     "    alternate.write_bytes(b'42')\n"
                     "    source.unlink()\n"
                     "    source.symlink_to(alternate)\n") +
                    f"    pathlib.Path({str(marker)!r}).write_text('mutated after extraction')\n" +
                    "sys.exit(result.returncode)\n")
                wrapper.chmod(0o755)
                launcher = self.base / (mode + "-driver")
                launcher.write_text(original_driver.replace(binaries[0], shlex.quote(str(wrapper))))
                launcher.chmod(0o755)
                self.driver = str(launcher)
                result, rows, output, _ = self.run_files(
                    {"c.nix": b"41", "raced.nix": b"42"}, folder="race-" + mode)
                self.assertEqual(marker.read_text(), "mutated after extraction")
                self.assert_refused_transaction(result, rows, output, "raced.nix", "source-snapshot-race")
                print(f"S2 post-extraction race/{mode}: refused, control preserved", flush=True)

    def test_compound_metadata_key_boundaries_preserve_control(self):
        def escaped(value):
            return value.replace("%", "%25").replace("|", "%7C")
        for framing in ("compound", "escaped"):
            for size in (LIMIT - 1, LIMIT, LIMIT + 1):
                with self.subTest(framing=framing, size=size):
                    prefix = "é" if framing == "compound" else "%|" * 64 + "é"
                    count = size - 200
                    while True:
                        logical = prefix + "x" * count
                        root_key = identity("root", logical, "snapshot-v1")
                        metadata_key = "nixql.s2.path|" + "|".join(map(escaped,
                            (root_key, "large.nix", sha(b"41")))) + "|[0]"
                        difference = size - len(metadata_key.encode())
                        if difference == 0:
                            break
                        count += difference
                    self.assertTrue(all(len(part.encode()) <= LIMIT
                        for part in (root_key, "large.nix", sha(b"41"))))
                    result, rows, output, _ = self.run_files(
                        {"c.nix": b"41", "large.nix": b"41"}, logical=logical,
                        folder=f"metadata-{framing}-{size}")
                    if size <= LIMIT:
                        self.accepted(result, rows)
                        strings = [value for path in (output / "trap").glob("syntax-*.trap")
                            for value in preflight.tuple_strings(path.read_text())]
                        self.assertIn(metadata_key, strings, "compound metadata did not round-trip")
                    else:
                        self.assert_refused_transaction(result, rows, output, "large.nix", "text-field-too-large")
                    print(f"S2 metadata-key {framing}/{size}: exact round-trip or atomic refusal", flush=True)

    def test_metadata_value_boundaries(self):
        spec = importlib.util.spec_from_file_location("s2_syntax", OWNER / "src/syntax.py")
        syntax = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(syntax)
        # Physical paths cannot reach MiB on real filesystems; exercise the
        # exact metadata value encoder separately from driver key transactions.
        for size in (LIMIT - 1, LIMIT, LIMIT + 1):
            value = 'é%|"' + "x" * (size - 5)
            self.assertEqual(len(value.encode()), size)
            if size <= LIMIT:
                row = syntax.metadata("file", ["root", "file.nix", "digest"], value, abi)
                self.assertEqual(list(preflight.tuple_strings(row)),
                    ["nixql.s2.file|root|file.nix|digest", value])
            else:
                with self.assertRaisesRegex(ValueError, "text-field-too-large"):
                    syntax.metadata("file", ["root", "file.nix", "digest"], value, abi)
            print(f"S2 metadata-value/{size}: exact round-trip or refusal", flush=True)

    def test_oversized_identity_retains_only_enclosing_failure(self):
        def separate_control(_, manifest):
            large = manifest["roots"][0]
            control = dict(large, logicalName="control", files=[large["files"][0]])
            large["files"] = large["files"][1:]
            manifest["roots"].insert(0, control)
        result, rows, output, _ = self.run_files(
            {"c.nix": b"41", "large.nix": b"42"}, logical="x" * LIMIT, mutate=separate_control)
        self.assert_refused_transaction(result, rows, output, "large.nix", "text-field-too-large")
        self.assertEqual([row[2] for row in self.table(rows, "nx_files")], ["c.nix"])
        self.assertIn("failed", [row[2] for row in self.table(rows, "nx_phases")])

    def test_root_escape_is_not_authenticated(self):
        outside = self.base / "outside.nix"
        outside.write_bytes(b"42")
        def escape(root, _):
            (root / "escape.nix").unlink()
            (root / "escape.nix").symlink_to(outside)
        result, rows, output, _ = self.run_files({"control.nix": b"41", "escape.nix": b"42"}, mutate=escape)
        self.assertNotEqual(result.returncode, 0)
        files = {row[2]: row[0] for row in self.table(rows, "nx_files")}
        if "escape.nix" in files:
            self.assertFalse(any(row[1] == files["escape.nix"] for row in self.table(rows, "nx_anchors")))
        self.assertFalse(list((output / "archive").rglob("escape.nix")))
        self.assertTrue(self.table(rows, "nx_diagnostics"))

    def test_driver_exact_text_boundaries_and_atomic_file_refusal(self):
        for size in (LIMIT - 1, LIMIT, LIMIT + 1):
            for name, text, source in (
                ("key", "x" * size, lambda value: "{" + value + " = 0;}"),
                ("utf8", "é" * (size // 2) + "x" * (size % 2), lambda value: '"' + value + '"'),
                ("quotes", "#" + '"' * (size - 1), lambda value: value + "\n0"),
                ("path", "./" + "x" * (size - 2), lambda value: value)):
                with self.subTest(field=name, size=size):
                    self.assertEqual(len(text.encode()), size)
                    result, rows, output, _ = self.run_files(
                        {"control.nix": b"41", "large.nix": source(text).encode()}, folder=f"{name}-{size}")
                    files = {row[2]: row[0] for row in self.table(rows, "nx_files")}
                    states = {row[0]: row[1] for row in self.table(rows, "nx_syntax_results")}
                    self.assertEqual(states[files["control.nix"]], "complete")
                    if size <= LIMIT:
                        self.accepted(result, rows)
                        strings = [value for path in (output / "trap").rglob("*.trap")
                            for value in preflight.tuple_strings(path.read_text())]
                        self.assertTrue(text in strings, "accepted raw text did not round-trip exactly")
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(states[files["large.nix"]], "failed")
                        self.assertIn("text-field-too-large", [row[2] for row in self.table(rows, "nx_diagnostics")])
                        self.assertFalse(any(row[1] == files["large.nix"] for row in self.table(rows, "nx_anchors")))
                        strings = [value for path in (output / "trap").rglob("*.trap")
                            for value in preflight.tuple_strings(path.read_text())]
                        self.assertTrue(strings, "completed control TRAP missing")
                        self.assertTrue(all(len(value.encode()) < 1024 for value in strings),
                            "rejected file published clipped or partial raw text")
                    print(f"S2 exact-text {name}/{size}: control preserved, expected acceptance/refusal", flush=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
