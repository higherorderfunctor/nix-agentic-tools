"""Exercise the index owner, explicit sources and the shared updater's publish boundary."""

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
import urllib.parse
from contextlib import nullcontext
from pathlib import Path

spec = importlib.util.spec_from_file_location("snapshot", sys.argv.pop(1))
snapshot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(snapshot)
kimchi = json.loads(Path(sys.argv.pop(1)).read_text())
kimchi_tree = Path(sys.argv.pop(1))
kimchi_date = (kimchi_tree / "ATTRIBUTION").read_text().split("Snapshot date: ")[1].splitlines()[0]
nix = sys.argv.pop(1)

# Known SHA-256 over the length-prefixed name and body of the explicit page.
PAGE = b"example documentation"
PAGE_DIGEST = "sha256-3mI/JpBaIZKGJiFIeo1gyc6mqV0kL2ef0iyQscjE8oI="


def captured_fetch(root):
    return lambda url: (root / urllib.parse.urlsplit(url).path.removeprefix("/")).read_bytes()


def tree_hash(path):
    return subprocess.check_output([nix, "--extra-experimental-features", "nix-command", "hash", "path", str(path)], text=True).strip()


def pin_text(content="old", output="old", date="2026-10-12"):
    return f'  snapshotDate = "{date}";\n  contentHash = "{content}";\n  hash = "{output}";\n'


class DocumentationSnapshot(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.pin = self.root / "package.nix"
        self.pin.write_text(pin_text())
        self.fetch = lambda _: PAGE
        validator = self.root / "validate"
        validator.write_text(f"#!{sys.executable}\nimport pathlib, sys\nif (pathlib.Path(sys.argv[1]) / 'page.md').read_bytes() != {PAGE!r}:\n    sys.exit(17)\n")
        validator.chmod(0o755)
        self.explicit = {"contentHash": "", "name": "fixture", "sources": [{"path": "page.md", "url": "https://example.test/page"}], "validate": str(validator)}

    def expected_hash(self, files):
        with tempfile.TemporaryDirectory(dir=self.root) as directory:
            expected = Path(directory)
            for name, body in files.items():
                (expected / name).write_bytes(body)
            return tree_hash(expected)

    def test_kimchi_walk_preserves_snapshot_bytes_and_hash(self):
        output = self.root / "kimchi"
        digest = snapshot.snapshot(kimchi, output, kimchi_date, captured_fetch(kimchi_tree))
        self.assertEqual(digest, kimchi["contentHash"])
        captured_hash = tree_hash(kimchi_tree)
        self.assertEqual(tree_hash(output), captured_hash)
        tomorrow = self.root / "tomorrow"
        self.assertEqual(snapshot.snapshot(kimchi, tomorrow, "2099-01-01", captured_fetch(kimchi_tree)), digest)
        self.assertNotEqual(tree_hash(tomorrow), captured_hash)
        self.pin.write_text(pin_text(kimchi["contentHash"], captured_hash, kimchi_date))
        before = self.pin.read_bytes(), self.pin.stat().st_mtime_ns
        self.assertFalse(snapshot.update(kimchi, self.pin, nix, "2099-01-01", captured_fetch(kimchi_tree)))
        self.assertEqual((self.pin.read_bytes(), self.pin.stat().st_mtime_ns), before)

    def test_changed_attribution_repairs_hash_without_advancing_date(self):
        date = "2026-10-12"
        original_hash = self.expected_hash({"ATTRIBUTION": b"Captured 2026-10-12\n", "page.md": PAGE})
        self.pin.write_text(pin_text(PAGE_DIGEST, original_hash, date))
        config = {**self.explicit, "generated": {"ATTRIBUTION": "Published {snapshot_date}\n"}}
        repaired_hash = self.expected_hash({"ATTRIBUTION": b"Published 2026-10-12\n", "page.md": PAGE})
        self.assertTrue(snapshot.update(config, self.pin, nix, "2099-01-01", self.fetch))
        self.assertEqual(self.pin.read_text(), pin_text(PAGE_DIGEST, repaired_hash, date))
        self.assertFalse(snapshot.update(config, self.pin, nix, "2099-02-02", self.fetch))

    def test_changed_content_publishes_hashes_then_noop_preserves_date(self):
        self.assertTrue(snapshot.update(self.explicit, self.pin, nix, "2099-01-01", self.fetch))
        self.assertEqual(self.pin.read_text(), pin_text(PAGE_DIGEST, self.expected_hash({"page.md": PAGE}), "2099-01-01"))
        before = self.pin.read_bytes(), self.pin.stat().st_mtime_ns
        self.assertFalse(snapshot.update(self.explicit, self.pin, nix, "2099-02-02", self.fetch))
        self.assertEqual((self.pin.read_bytes(), self.pin.stat().st_mtime_ns), before)

    def test_fetch_or_owner_parser_failure_preserves_pin(self):
        original = self.pin.read_bytes()
        with self.assertRaises(subprocess.CalledProcessError) as rejected:
            snapshot.update(self.explicit, self.pin, nix, "2099-01-01", lambda _: b"<html>login</html>")
        self.assertEqual(rejected.exception.cmd[0], self.explicit["validate"])
        self.assertEqual(rejected.exception.returncode, 17)
        self.assertEqual(self.pin.read_bytes(), original)

        def broken_fetch(_):
            raise OSError("upstream unavailable")

        with self.assertRaisesRegex(OSError, "upstream unavailable"):
            snapshot.update(self.explicit, self.pin, nix, "2099-01-01", broken_fetch)
        self.assertEqual(self.pin.read_bytes(), original)

    def test_checked_publish_refuses_concurrent_change(self):
        edited = self.pin.read_text() + "# concurrent edit\n"

        def edit_during_fetch(url):
            self.pin.write_text(edited)
            return self.fetch(url)

        with self.assertRaisesRegex(RuntimeError, "changed during update"):
            snapshot.update(self.explicit, self.pin, nix, "2099-01-01", edit_during_fetch)
        self.assertEqual(self.pin.read_text(), edited)

    def test_update_refuses_ambiguous_pin(self):
        ambiguous = self.pin.read_text() + '  contentHash = "duplicate";\n'
        self.pin.write_text(ambiguous)
        with self.assertRaisesRegex(ValueError, "expected exactly one recipe field: contentHash"):
            snapshot.update(self.explicit, self.pin, nix, "2099-01-01", self.fetch)
        self.assertEqual(self.pin.read_text(), ambiguous)

    def test_kimchi_published_tree_urls(self):
        origin = "https://docs.kimchi.dev"
        rows = {
            "denied path": (origin + "/login", r"robots\.txt disallows documentation path"),
            "denied segment": (origin + "/docs/cdn-cgi/page", r"robots\.txt disallows documentation path"),
            "empty segment": (origin + "/docs//page", "invalid documentation path"),
            "encoded traversal": (origin + "/docs/%2e%2e/page", "invalid documentation URL"),
            "http": ("http://docs.kimchi.dev/docs/page", "invalid documentation URL"),
            "outside tree": (origin + "/other/page", "outside the published index tree"),
            "parent segment": (origin + "/docs/../page", "invalid documentation path"),
            "published index": (origin + "/llms.txt", None),
            "query": (origin + "/docs/page?secret=1", "invalid documentation URL"),
        }
        responses = {origin + "/llms.txt": b"[Page](/docs/page.md)", origin + "/docs/page.md": b"page"}
        for name, (url, error) in rows.items():
            with self.subTest(name=name):
                config = {**kimchi, "index": {**kimchi["index"], "url": url, "requiredIndexes": []}}
                output = self.root / name
                with self.assertRaisesRegex(ValueError, error) if error else nullcontext():
                    snapshot.snapshot(config, output, "2099-01-01", responses.__getitem__)
                if not error:
                    self.assertEqual((output / "docs/page.md").read_bytes(), b"page")

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

    def test_source_normalize_runs_before_content_identity(self):
        normalize = self.root / "normalize"
        # Drops the first line, as a catalog normalizer drops its fetch stamp.
        normalize.write_text(f"#!{sys.executable}\nimport sys\nsys.stdout.write(sys.stdin.read().partition(chr(10))[2])\n")
        normalize.chmod(0o755)
        config = {"name": "normalized", "contentHash": "", "sources": [{"path": "catalog.json", "url": "https://example.com/catalog", "normalize": str(normalize)}]}
        digests = [snapshot.snapshot(config, self.root / f"normalized-{stamp}", "2099-01-01", lambda _, stamp=stamp: f"created {stamp}\nstable".encode()) for stamp in (1, 2)]
        self.assertEqual(digests[0], digests[1])
        self.assertEqual((self.root / "normalized-1/catalog.json").read_bytes(), b"stable")
        with self.assertRaisesRegex(ValueError, "empty normalized"):
            snapshot.snapshot(config, self.root / "empty", "2099-01-01", lambda _: b"only one line")

    def test_explicit_destination_cannot_escape_or_overwrite(self):
        rows = {
            "absolute": ([str(self.root / "outside.md")], "invalid snapshot path"),
            "duplicate": (["models.md", "models.md"], r"duplicate snapshot path: models\.md"),
            "empty": ([""], "invalid snapshot path: $"),
            "relative": (["models.md"], None),
            "traversal": (["../models.md"], r"invalid snapshot path: \.\./models\.md"),
        }
        responses = {"https://example.test/0": b"data", "https://example.test/1": b"other"}
        for name, (paths, error) in rows.items():
            with self.subTest(name=name):
                config = {"sources": [{"path": path, "url": f"https://example.test/{i}"} for i, path in enumerate(paths)]}
                output = self.root / name
                with self.assertRaisesRegex(ValueError, error) if error else nullcontext():
                    snapshot.snapshot(config, output, "2099-01-01", responses.__getitem__)
                if not error:
                    self.assertEqual((output / "models.md").read_bytes(), b"data")


unittest.main()
