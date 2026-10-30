"""Exercise both configured owners and the shared updater's publish boundary."""

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
import urllib.parse
from pathlib import Path

spec = importlib.util.spec_from_file_location("snapshot", sys.argv.pop(1))
snapshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snapshot)
kimchi = json.loads(Path(sys.argv.pop(1)).read_text())
kimchi_tree = Path(sys.argv.pop(1))
kimchi_date = (kimchi_tree / "ATTRIBUTION").read_text().split("Snapshot date: ")[1].splitlines()[0]
kiro = json.loads(Path(sys.argv.pop(1)).read_text())
kiro_tree = Path(sys.argv.pop(1))
nix, fail = sys.argv[1:3]
del sys.argv[1:3]


def captured_fetch(root):
    return lambda url: (root / urllib.parse.urlsplit(url).path.removeprefix("/")).read_bytes()


def tree_hash(path):
    return subprocess.check_output([nix, "--extra-experimental-features", "nix-command", "hash", "path", str(path)], text=True).strip()


class DocumentationSnapshot(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.pin = self.root / "package.nix"
        self.pin.write_text('  snapshotDate = "2026-10-12";\n  contentHash = "old";\n  hash = "old";\n')
        self.config = kiro
        self.fetch = lambda _: (kiro_tree / "models.md").read_bytes()

    def test_kimchi_walk_preserves_snapshot_bytes_and_hash(self):
        output = self.root / "kimchi"
        digest = snapshot.snapshot(kimchi, output, kimchi_date, captured_fetch(kimchi_tree))
        self.assertEqual(digest, kimchi["contentHash"])
        self.assertEqual(tree_hash(output), tree_hash(kimchi_tree))
        tomorrow = self.root / "tomorrow"
        self.assertEqual(snapshot.snapshot(kimchi, tomorrow, "2099-01-01", captured_fetch(kimchi_tree)), digest)
        self.assertNotEqual(tree_hash(output), tree_hash(tomorrow))
        self.pin.write_text(self.pin.read_text().replace('contentHash = "old";', f'contentHash = "{digest}";').replace('hash = "old";', f'hash = "{tree_hash(kimchi_tree)}";').replace('2026-10-12', kimchi_date))
        before = self.pin.read_bytes(), self.pin.stat().st_mtime_ns
        self.assertFalse(snapshot.update(kimchi, self.pin, nix, "2099-01-01", captured_fetch(kimchi_tree)))
        self.assertEqual((self.pin.read_bytes(), self.pin.stat().st_mtime_ns), before)

    def test_changed_attribution_repairs_hash_without_advancing_date(self):
        snapshot.update(kimchi, self.pin, nix, kimchi_date, captured_fetch(kimchi_tree))
        original = snapshot.pin_fields(self.pin.read_text())
        config = {**kimchi, "generated": {"ATTRIBUTION": kimchi["generated"]["ATTRIBUTION"] + "Additional attribution.\n"}}
        self.assertTrue(snapshot.update(config, self.pin, nix, "2099-01-01", captured_fetch(kimchi_tree)))
        changed = snapshot.pin_fields(self.pin.read_text())
        self.assertEqual(changed["contentHash"], original["contentHash"])
        self.assertEqual(changed["snapshotDate"], original["snapshotDate"])
        self.assertNotEqual(changed["hash"], original["hash"])
        self.assertFalse(snapshot.update(config, self.pin, nix, "2099-02-02", captured_fetch(kimchi_tree)))

    def test_changed_content_publishes_hashes_then_noop_preserves_date(self):
        self.assertTrue(snapshot.update(self.config, self.pin, nix, "2099-01-01", self.fetch))
        fields = snapshot.pin_fields(self.pin.read_text())
        self.assertEqual(fields["snapshotDate"], "2099-01-01")
        self.assertEqual(fields["contentHash"], snapshot.content_hash(kiro_tree))
        self.assertEqual(fields["hash"], tree_hash(kiro_tree))
        before = self.pin.read_bytes(), self.pin.stat().st_mtime_ns
        self.assertFalse(snapshot.update(self.config, self.pin, nix, "2099-02-02", self.fetch))
        self.assertEqual((self.pin.read_bytes(), self.pin.stat().st_mtime_ns), before)

    def test_fetch_or_owner_parser_failure_preserves_pin(self):
        original = self.pin.read_bytes()
        for fetch in (lambda _: b"<html>login</html>", lambda _: b"## Quick comparison\n| Model | Context |\n| --- | --- |\n| Auto | 1M |\n| Mystery 99 | 1M |\n"):
            with self.assertRaises(subprocess.CalledProcessError):
                snapshot.update(self.config, self.pin, nix, "2099-01-01", fetch)
            self.assertEqual(self.pin.read_bytes(), original)
        def broken_fetch(_):
            raise OSError("upstream unavailable")
        with self.assertRaises(OSError):
            snapshot.update(self.config, self.pin, nix, "2099-01-01", broken_fetch)
        self.assertEqual(self.pin.read_bytes(), original)

    def test_checked_publish_refuses_concurrent_change_and_ambiguous_pin(self):
        original = self.pin.read_text()
        self.pin.write_text(original + "# concurrent edit\n")
        with self.assertRaisesRegex(RuntimeError, "changed during update"):
            snapshot.publish(self.pin, original, "replacement")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            snapshot.pin_fields(original + original)

    def test_kimchi_refuses_paths_outside_published_tree(self):
        for suffix in ("/docs/../page", "/docs//page", "/docs/cdn-cgi/page", "/login", "/other/page", "/docs/page?secret=1", "/docs/%2e%2e/page"):
            with self.subTest(suffix=suffix), self.assertRaises(ValueError):
                snapshot.validate_url("https://docs.kimchi.dev" + suffix, kimchi["index"])
        with self.assertRaises(ValueError):
            snapshot.validate_url("http://docs.kimchi.dev/docs/page", kimchi["index"])

    def test_index_walk_resolves_relative_links_ignores_external_and_breaks_cycles(self):
        root_url = "https://docs.kimchi.dev/llms.txt"
        index_url = "https://docs.kimchi.dev/docs/llms.txt"
        responses = {
            root_url: b"[Docs](/docs/llms.txt) [Reference](/reference/llms.txt) [Cycle](/llms.txt)",
            index_url: b"[Root](/docs/root.md) [Relative](relative.md) [Absolute](https://docs.kimchi.dev/docs/absolute.md) [External](https://example.com/docs/external.md) [Native](/docs/native)",
            "https://docs.kimchi.dev/docs/root.md": b"root",
            "https://docs.kimchi.dev/docs/relative.md": b"relative",
            "https://docs.kimchi.dev/docs/absolute.md": b"absolute",
            "https://docs.kimchi.dev/docs/native.md": b"native",
            "https://docs.kimchi.dev/reference/llms.txt": b"[Endpoint](endpoint.md)",
            "https://docs.kimchi.dev/reference/endpoint.md": b"endpoint",
        }
        fetched = []
        def fetch(url):
            fetched.append(url)
            return responses[url]
        snapshot.snapshot(kimchi, self.root / "walk", "2099-01-01", fetch)
        self.assertEqual(sorted(fetched), sorted(responses))
        self.assertEqual((self.root / "walk/docs/relative.md").read_bytes(), b"relative")
        self.assertEqual((self.root / "walk/reference/endpoint.md").read_bytes(), b"endpoint")

    def test_required_index_cannot_silently_disappear(self):
        config = {**kimchi, "index": {**kimchi["index"], "requiredIndexes": ["https://docs.kimchi.dev/docs/missing/llms.txt"]}}
        with self.assertRaisesRegex(ValueError, "required documentation indexes"):
            snapshot.snapshot(config, self.root / "missing", "2099-01-01", captured_fetch(kimchi_tree))

    def test_explicit_destination_cannot_escape_or_overwrite(self):
        self.root.joinpath("snapshot").mkdir()
        for path in ("../models.md", "/models.md", ""):
            with self.subTest(path=path), self.assertRaises(ValueError):
                snapshot.write_page(self.root / "snapshot", path, b"data")
        snapshot.write_page(self.root / "snapshot", "models.md", b"data")
        with self.assertRaisesRegex(ValueError, "duplicate"):
            snapshot.write_page(self.root / "snapshot", "models.md", b"other")


unittest.main()
