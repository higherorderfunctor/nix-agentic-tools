"""Independent regressions for P2a's authenticated failure boundary."""

import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

OWNER = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(OWNER / "src/eval"))
import supervisor
import extract
import syntax

abi = supervisor.abi


class ReviewRegressions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.scratch = Path(self.temp.name)
        self.root = self.scratch / "project"
        (self.root / ".nixql").mkdir(parents=True)
        (self.root / ".nixql/targets.nix").write_text("41")
        self.dependency = self.scratch / "dependency"
        self.dependency.mkdir()
        (self.dependency / "value.nix").write_text("17")
        self.pins = self.scratch / "pins.json"
        self.pins.write_text('{"grammar":"review-grammar"}')
        self.trap = self.scratch / "trap"
        self.archive = self.scratch / "archive"
        self.discoveries = 0
        self.hashes = {}
        self.race = False
        self.change_after_evaluation = False
        self.staged = {}
        self.packet = None

    @staticmethod
    def tree_hash(path):
        return hashlib.sha256(b"".join(file.relative_to(path).as_posix().encode() + file.read_bytes()
            for file in sorted(path.rglob("*")) if file.is_file())).hexdigest()

    def execute(self, argv, job, request, directory, deadline, env):
        if argv[0] == sys.executable:
            return self.real_execute(argv, job, request, directory, deadline, env)
        if "hash" in argv:
            path = Path(argv[-1])
            value = self.tree_hash(path)
            count = self.hashes.get(path, 0) + 1
            self.hashes[path] = count
            if self.race and path == self.dependency:
                # Restore A after the second hash: a final rehash cannot catch
                # the transient B that discovery would otherwise adopt.
                (path / "value.nix").write_text("23" if count == 1 else "17")
            return value
        self.discoveries += 1
        roots = job["target"]["sourceRoots"]
        target = {
            "adapter": "evalModules", "adapterVersion": "1",
            "argumentDescription": {"hash": "arguments", "moduleArgumentsRef": "module", "specialArgumentsRef": "special"},
            "evaluation": {"kind": "rich-result", "reference": "evaluation"},
            "fingerprint": {"evaluatorVersion": "test", "libVersion": "test", "modelVersion": "not-requested", "policyHash": "test", "sourceSnapshotHash": "admitted"},
            "inputIdentities": {"project": "test"}, "observationModes": ["metadata"],
            "requests": [{"domain": "option-metadata", "facet": "isDefined", "path": [mode],
                "maxBytes": 16384, "maxDepth": 0, "maxMemoryMiB": 256, "maxNodes": 10, "maxSeconds": 4} for mode in ("ok", "crash")],
            "sourceRoots": [root | {"logicalName": "project" if index == 0 else "dependency", "rootContentIdentity": "admitted"}
                for index, root in enumerate(roots)],
            "syntaxOnlyFallback": False, "system": "x86_64-linux",
        }
        result = {"manifest": {"manifestVersion": 1, "targets": {"review": target}},
            "bindings": {"evaluation": {"command": [sys.executable, str(OWNER / "checks/fixtures/eval-isolation/producer.py")]},
                "module": {}, "special": {}}}
        return json.dumps({"trees": [root["path"] for root in roots], "result": result})

    def syntax(self, binary, schema, combined, pins, manifest, staged, identity, trap, archive):
        archive.mkdir()
        trap.mkdir()
        facts = [identity.row, ["nx_phases", [identity.row[1][0], "syntax", "complete", "review fixture"]]]
        supervisor.publish(trap, "syntax", facts[1:])
        return 0, {"protocolVersion": 1, "facts": facts}

    def supervise(self, *args, **kwargs):
        self.packet = self.real_supervise(*args, **kwargs)
        self.staged = {path.name: path.read_bytes() for path in Path(args[2]).glob("*.trap")}
        if self.change_after_evaluation:
            (self.dependency / "value.nix").write_text("23")
        return self.packet

    def run_coordinator(self):
        self.real_execute = supervisor.execute
        self.real_supervise = supervisor.supervise
        env = {"CODEQL_EXTRACTOR_NIX_SOURCE_ROOT": str(self.root),
            "CODEQL_EXTRACTOR_NIX_TRAP_DIR": str(self.trap),
            "CODEQL_EXTRACTOR_NIX_SOURCE_ARCHIVE_DIR": str(self.archive),
            "CODEQL_EXTRACTOR_NIX_OPTION_INPUTS": json.dumps({"dependency": {
                "path": str(self.dependency), "narHash": self.tree_hash(self.dependency)}})}
        argv = ["extract.py", __file__, str(OWNER / "schema"), str(OWNER / "generated/nix.dbscheme"), str(self.pins), "test-nix"]
        with patch.dict(os.environ, env), patch.object(sys, "argv", argv), \
                patch.object(supervisor, "execute", self.execute), \
                patch.object(supervisor, "supervise", self.supervise), \
                patch.object(syntax, "extract", self.syntax), contextlib.redirect_stderr(io.StringIO()):
            return extract.main()

    def test_discovery_refuses_transient_dependency_change_against_initial_pin(self):
        self.race = True
        self.assertEqual(self.run_coordinator(), 1)
        self.assertEqual(self.discoveries, 0, "changed input must be refused before discovery evaluation")
        text = (self.trap / "coordinator.trap").read_text()
        self.assertIn("mixed-source-snapshot", text)
        self.assertIn('"discovery", "failed"', text)
        self.assertEqual((self.dependency / "value.nix").read_text(), "17")

    def test_incomplete_run_preserves_validated_completed_request_and_failure_facts(self):
        self.assertEqual(self.run_coordinator(), 1)
        abi.validate(self.packet["facts"])
        results = [args for relation, args in self.packet["facts"] if relation == "nx_request_results"]
        self.assertCountEqual([row[1] for row in results], ["complete", "failed"])
        self.assertTrue(self.staged)
        for name, contents in self.staged.items():
            self.assertEqual((self.trap / name).read_bytes(), contents)
        text = "".join(path.read_text() for path in self.trap.glob("*.trap"))
        self.assertEqual(text.count("nx_runs("), 1)
        self.assertEqual(text.count("nx_request_results("), 2)
        self.assertIn("nx_option_metadata(", text)
        self.assertIn("nx_diagnostic_requests(", text)
        self.assertIn('"evaluation", "partial"', text)
        self.assertNotIn('"extraction-refused"', text)

    def test_incomplete_run_never_promotes_changed_snapshot(self):
        self.change_after_evaluation = True
        self.assertEqual(self.run_coordinator(), 1)
        self.assertTrue(self.staged)
        self.assertEqual([path.name for path in self.trap.glob("*.trap")], ["coordinator.trap"])
        text = (self.trap / "coordinator.trap").read_text()
        self.assertIn("mixed-source-snapshot", text)
        self.assertNotIn("nx_option_metadata(", text)

    def test_syntax_path_import_preserves_callers_module_search_path(self):
        script = '''import importlib.util, sys
before = list(sys.path)
spec = importlib.util.spec_from_file_location("standalone_syntax", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
assert sys.path == before
assert module.quote('a"b') == '"a""b"'
'''
        result = subprocess.run([sys.executable, "-I", "-B", "-c", script, str(OWNER / "src/syntax.py")], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
