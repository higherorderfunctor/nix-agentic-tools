"""Production-boundary regressions for installed session reuse."""

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "installed"))
from installed_session import tree_digest
import test_installed

ROOT = Path(__file__).resolve().parents[3]


class InstalledBoundaryTests(unittest.TestCase):
    def test_real_create_boundary_reuses_exact_run(self):
        with tempfile.TemporaryDirectory() as temporary:
            root, source, dependency = Path(temporary), Path(temporary) / "source", Path(temporary) / "nixpkgs"
            source.mkdir(); (source / ".nixql").mkdir(); dependency.mkdir()
            (source / "default.nix").write_text("17"); (dependency / "default.nix").write_text("23")
            env = os.environ | {"HOME": str(root / "home"), "NIX_CONFIG": "experimental-features =\n", "NIX_PATH": ""}
            Path(env["HOME"]).mkdir()
            hashed = subprocess.run([os.environ["CODEQL_NIX_TEST_NIX"], "--extra-experimental-features", "nix-command",
                                     "hash", "path", str(dependency)], env=env, capture_output=True, text=True,
                                    check=True).stdout.strip()
            (source / ".nixql/targets.nix").write_text(f'''{{ inputs, source }}: let
              ordinary = {{ logicalName = "ordinary"; path = toString source; }};
              alias = ordinary // {{ logicalName = "alias"; }};
              dependency = {{ logicalName = "nixpkgs"; path = toString inputs.nixpkgs.outPath; }};
            in {{ manifest.targets = {{
              ordinary.sourceRoots = [ ordinary dependency ];
              alias.sourceRoots = [ alias dependency ];
            }}; bindings = {{}}; }}''')
            tools = root / "extractor/tools"; tools.mkdir(parents=True)
            pins, command = root / "pins.json", root / "command"
            pins.write_text(json.dumps({"grammar": "grammar", "model": "model", "moduleModel": {}}))
            command.write_bytes(b"product")
            (tools / "autobuild.sh").write_text(
                f'exec {sys.executable} {ROOT}/src/extract.py {ROOT}/src/extract.py {ROOT}/schema '
                f'{root / "schema"} {pins} {os.environ["CODEQL_NIX_TEST_NIX"]}\n')
            (root / "schema").write_bytes(b"schema")
            (root / "library/models").mkdir(parents=True)
            (root / "library/models/modules.json").write_text(json.dumps({"bundleHash": "model"}))
            case = test_installed.InstalledTests("create")
            case.extractor, case.library, case.command = root / "extractor", root / "library", command
            case.nix, case.inputs = Path(os.environ["CODEQL_NIX_TEST_NIX"]), {"nixpkgs": {"path": str(dependency), "narHash": hashed}}
            case.scratch, case.root, case.session, case.env = root, source, test_installed.Session(root / "session"), env
            with mock.patch.dict(sys.modules, {"jsonschema": None}):
                invocation, _, abi = case.installed_authority()
            self.assertEqual(Path(invocation[4]) / "abi.py", Path(abi.__file__))
            expected = case.requested_run_identity(source / ".nixql/targets.nix", case.inputs)
            failures, state, commands = iter(("duplicate-run", "wrong-snapshot", "failed-phase")), {}, []

            def run_codeql(*args, **_):
                commands.append(args[:2])
                if args[:2] == ("database", "create"):
                    Path(args[2]).mkdir(parents=True, exist_ok=True)
                return subprocess.CompletedProcess(args, 0, "", "")

            def query(_database, name, _body):
                if name == "SessionPhases":
                    return [["discovery", "failed" if state.get("failure") == "failed-phase" else "complete"]]
                state["failure"] = next(failures, None)
                row = ["1", *expected.row[1][1:]]
                if state["failure"] == "duplicate-run":
                    return [tuple(["2", *row[1:]])]
                if state["failure"] == "wrong-snapshot":
                    row[-1] = "wrong-snapshot"
                return [tuple(row)]

            case.run_codeql, case.query = run_codeql, query
            log = root / "misses"; os.environ["CODEQL_NIX_TEST_SESSION_MISS_LOG"] = str(log)
            for _ in range(3):
                with self.assertRaises(AssertionError):
                    case.create()
            database, executed = case.create(); reused, cache_hit = case.create()
            self.assertEqual(executed.returncode, 0); self.assertIsNone(cache_hit); self.assertEqual(database, reused)
            self.assertEqual((commands.count(("database", "create")), len(log.read_text().splitlines())), (4, 4))

    def test_source_identity_and_query_suites_are_explicit(self):
        with tempfile.TemporaryDirectory() as temporary:
            source, first, second = Path(temporary), Path(temporary) / "a", Path(temporary) / "b"
            first.write_bytes(b"first"); second.write_bytes(b"second")
            key = tree_digest(source)
            mode = second.stat().st_mode
            framing = json.dumps(["b", "file", stat.S_IFMT(mode), mode & 0o777], separators=(",", ":")).encode()
            first.write_bytes(b"first\0" + framing + b"\0second"); second.unlink()
            self.assertNotEqual(key, tree_digest(source))
        expected = {
            "metadata.qls": ["DisabledModules.ql", "ExtractionHealth.ql", "ModuleSelection.ql", "RenamedOptions.ql", "WhoSetsOption.ql"],
            "source.qls": ["DirectoryImports.ql", "ImportGraph.ql", "NameBindings.ql", "RenamedOptions.ql"],
            "values.qls": [],
        }
        for name, queries in expected.items():
            text = (ROOT / "ql/suites" / name).read_text()
            paths = [line.removeprefix("- query: ") for line in text.splitlines() if line.startswith("- query:")]
            self.assertEqual(paths, queries)
