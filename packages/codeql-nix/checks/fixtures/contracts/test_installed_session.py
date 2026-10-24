"""I9s session behavior with fake finalized databases, never CodeQL creates."""

import copy
import multiprocessing
from pathlib import Path
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from installed_session import Session, variant_key


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.source.mkdir()
        (self.source / "default.nix").write_text("17")
        self.fields = dict(inputs={"nixpkgs": {"narHash": "pin"}}, manifest="manifest",
                           options={"targets": "default"}, identities={
                               "extractor": "e", "model": "m", "product": "p",
                               "schema": "s", "snapshot": "snapshot"}, failure="success")
        self.session = Session(self.root / "session")

    def key(self, **updates):
        return variant_key(self.source, **(self.fields | updates))

    def build(self, path):
        path.mkdir(parents=True, exist_ok=True)
        (path / "ready").write_text("schema:s;model:m;snapshot:snapshot;phase:complete")

    def validate(self, path):
        if not (path / "ready").is_file() or (path / "ready").read_text() != "schema:s;model:m;snapshot:snapshot;phase:complete":
            raise ValueError("identity or completed health mismatch")

    def test_key_tracks_bytes_pins_manifest_options_identities_and_failure(self):
        key = self.key()
        self.assertEqual(key, self.key())
        (self.source / "default.nix").write_text("23")
        self.assertNotEqual(key, self.key())
        (self.source / "default.nix").write_text("17")
        for field in self.fields:
            changes = copy.deepcopy(self.fields)
            changes[field] = "changed" if isinstance(changes[field], str) else changes[field] | {"changed": "changed"}
            self.assertNotEqual(key, self.key(**changes), field)
        for identity in self.fields["identities"]:
            self.assertNotEqual(key, self.key(identities=self.fields["identities"] | {identity: "changed"}))
        (self.source / "extra.nix").write_text("17")
        self.assertNotEqual(key, self.key())

    def test_only_finalized_validated_database_is_reused(self):
        calls = []
        def build(path):
            calls.append(path)
            self.build(path)
        database = self.session.database(self.key(), build, self.validate)
        self.assertEqual(database, self.session.database(self.key(), build, self.validate))
        self.assertEqual(len(calls), 1)
        self.validate(database)
        (database / "ready").write_text("schema:wrong;phase:complete")
        with self.assertRaises(ValueError):
            self.session.database(self.key(), build, self.validate)

    def test_failed_build_and_empty_health_never_publish(self):
        key = self.key()
        def broken(path):
            self.build(path)
            raise RuntimeError("finalization failed")
        with self.assertRaisesRegex(RuntimeError, "finalization"):
            self.session.database(key, broken, self.validate)
        with self.assertRaises(ValueError):
            self.session.database(key, lambda path: path.mkdir(exist_ok=True), self.validate)
        self.validate(self.session.database(key, self.build, self.validate))
        self.assertEqual(len(list((self.root / "session").rglob("ready"))), 1)

    def test_explicit_session_path_locks_and_reuses_across_processes(self):
        context = multiprocessing.get_context("fork")
        start = context.Event()
        count = self.root / "builds"
        def worker():
            start.wait(10)
            def build(path):
                with count.open("a") as stream:
                    stream.write("create\n")
                time.sleep(0.05)
                self.build(path)
            database = Session(self.root / "session").database(self.key(), build, self.validate)
            self.validate(database)
        processes = [context.Process(target=worker) for _ in range(3)]
        for process in processes:
            process.start()
            self.addCleanup(lambda p=process: p.kill() if p.is_alive() else None)
        start.set()
        for process in processes:
            process.join(15)
            self.assertEqual(process.exitcode, 0)
        self.assertEqual(count.read_text(), "create\n")
