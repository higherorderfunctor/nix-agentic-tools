"""Q0 independent contract: upstream lib.evalModules and handwritten rows.

Reuse P2a's installed lifecycle harness; load_tests selects only Q0 methods.
"""

import json
from pathlib import Path
import shutil
import subprocess
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "installed"))
import test_installed

OWNER = Path(__file__).resolve().parents[3]
PATH = '["demo","answer"]'
CASES = ("equal", "ordinary", "unselected")


class Step0Tests(test_installed.InstalledTests):
    def fixture(self):
        shutil.copytree(Path(__file__).parent / "q0", self.root, dirs_exist_ok=True)
        for path in (self.root, *self.root.rglob("*")):
            path.chmod(path.stat().st_mode | 0o200)

    def query_product(self, database, name):
        return self.installed_query(database, name)

    def oracle(self, case, success=True):
        arguments = {"case": case, "nixpkgs": self.inputs["nixpkgs"]["path"], "source": str(self.root)}
        apply = "oracle: oracle { " + " ".join(name + " = " + json.dumps(value) + ";" for name, value in arguments.items()) + " }"
        result = subprocess.run([self.nix, "--extra-experimental-features", "nix-command", "eval", "--json", "--impure",
            "--file", str(Path(__file__).with_name("oracle.nix")),
            "--apply", apply],
            env=self.env, capture_output=True, text=True)
        if not success:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Q0 selected failure", result.stderr)
            return
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def assert_selected(self, rows, case, files, priority):
        expected = [["selected", case, PATH, file, "unknown", "unknown", priority, "true", "unique"] for file in files]
        self.assertCountEqual([row for row in rows if row[:2] == ["selected", case]], expected)
        oracle = self.oracle(case)
        oracle["files"].sort()
        self.assertEqual(oracle, {"declarations": ["options.nix"], "files": sorted(files), "priority": priority})

    def test_installed_q0_and_independent_priority_flip(self):
        self.fixture()
        database, _ = self.create()
        rows = self.query_product(database, "WhoSetsOption")
        expected = [line.strip()[2:-2].split(" | ") for line in (OWNER / "ql/test/step0/WhoSetsOption.expected").read_text().splitlines()]
        self.assertCountEqual(rows, expected)
        for case in CASES:
            self.assert_selected(rows, case, ["equal.nix", "ordinary.nix"] if case == "equal" else ["ordinary.nix"], "100")
        health = self.query_product(database, "ExtractionHealth")
        for phase in ("discovery", "evaluation", "syntax"):
            reason = "all-selected-files" if phase == "syntax" else ""
            self.assertIn(["phase", "", "", phase, "complete", reason, ""], health)
        requests = [row for row in health if row[0] == "request"]
        self.assertCountEqual(requests, [["request", case, PATH, facet, "complete", "", str(count)]
            for case in CASES for facet, count in (("declarations", 2), ("definitions", 3 if case == "equal" else 2), ("priority", 1))])
        self.assertFalse([row for row in health if row[0] == "diagnostic"])
        (self.root / "default.nix").write_text((self.root / "default.nix").read_text().replace("lib.mkDefault", "lib.mkOverride 50"))
        changed, _ = self.create("override-db")
        flipped = self.query_product(changed, "WhoSetsOption")
        self.assert_selected(flipped, "ordinary", ["default.nix"], "50")
        for row in flipped:
            if row[0] == "candidate":
                self.assertEqual(row[6:8], ["unknown", "unknown"])

    def test_installed_qltest_runs_frozen_expected_rows(self):
        self.root = self.scratch / "ql/test/step0"
        self.root.mkdir(parents=True)
        self.fixture()
        shutil.copy(OWNER / "ql/test/qlpack.yml", self.root.parent / "qlpack.yml")
        for name in ("WhoSetsOption.ql", "WhoSetsOption.expected"):
            shutil.copy(OWNER / "ql/test/step0" / name, self.root / name)
        self.run_codeql("test", "run", "ql/test/step0",
            env=self.env | {"CODEQL_EXTRACTOR_NIX_OPTION_INPUTS": json.dumps(self.inputs)})

    def test_shared_source_aliases_preserve_target_identity_and_unknown_ambiguous_files(self):
        self.fixture()
        target = self.root / ".nixql/targets.nix"
        target.rename(target.with_name("base.nix"))
        target.write_text('''{inputs, source}: let
          base = import ./base.nix { inherit inputs source; };
          ordinary = base.manifest.targets.ordinary;
          project = builtins.head ordinary.sourceRoots;
          dependencies = builtins.tail ordinary.sourceRoots;
          alias = project // { logicalName = "alternate"; };
        in base // { manifest = base.manifest // { targets = {
          first = ordinary;
          second = ordinary // { sourceRoots = [alias] ++ dependencies; };
          ambiguous = ordinary // { sourceRoots = [project alias] ++ dependencies; };
        }; }; }''')
        database, _ = self.create()
        rows = self.query_product(database, "WhoSetsOption")
        selected = [row for row in rows if row[0] == "selected"]
        self.assertEqual(len(selected), 3)
        for name in ("first", "second"):
            row = next(row for row in selected if row[1] == name)
            self.assertEqual(row[2:], [PATH, "ordinary.nix", "unknown", "unknown", "100", "true", "unique"])
        self.assertIn(["selected", "ambiguous", PATH, "unknown", "unknown", "unknown", "100", "true", "unmapped"], selected)
        self.assertIn(["declaration", "ambiguous", PATH, "unknown", "unknown", "unknown", "unknown", "unknown", "unknown"], rows)
        for name in ("ambiguous", "first", "second"):
            candidates = [row for row in rows if row[:2] == ["candidate", name]]
            self.assertCountEqual([row[3] for row in candidates],
                                 ["default.nix", "equal.nix", "ordinary.nix", "unselected.nix"])
            self.assertTrue(all(row[6:8] == ["unknown", "unknown"] for row in candidates))
            ordinary = next(row for row in candidates if row[3] == "ordinary.nix")
            self.assertEqual(ordinary[8], "unknown" if name == "ambiguous" else "unique")
        count = len(list(self.root.rglob("*.nix")))
        admissions = self.query(database, "AliasAdmissions", '''from @nx_target t, string name
          where nx_targets(t, _, name, _, _, _, _, _, _, _)
          select name, count(@nx_file f | nx_target_inputs(t, f, _) | f),
            count(string root | exists(@nx_file f | nx_target_inputs(t, f, _) and nx_files(f, root, _, _, _)) | root)''')
        self.assertCountEqual(admissions, [["first", str(count), "1"], ["second", str(count), "1"],
                                          ["ambiguous", str(2 * count), "2"]])

    def test_selected_failure_has_health_and_unknown_candidates(self):
        self.fixture()
        target = self.root / ".nixql/targets.nix"
        target.write_text(target.read_text().replace('["equal" "ordinary" "unselected"]', '["failure"]'))
        self.oracle("failure", success=False)
        database, result = self.create(success=False)
        self.assertNotEqual(result.returncode, 0, "selected failure must not produce empty success")
        self.run_codeql("database", "finalize", database)
        rows = self.query_product(database, "WhoSetsOption")
        self.assertEqual(len(rows), 4)
        self.assertTrue(all(row[0] == "candidate" and row[1] == "failure" and row[6:] == ["unknown", "unknown", "unknown"] for row in rows))
        health = self.query_product(database, "ExtractionHealth")
        requests = [row for row in health if row[0] == "request"]
        self.assertEqual(len(requests), 3)
        self.assertTrue(all(row[1] == "failure" and row[2] == PATH and row[4] == "failed" and row[5] and row[6] == "0" for row in requests))
        self.assertTrue(any(row[0] == "phase" and row[3:5] == ["evaluation", "partial"] for row in health))
        self.assertTrue(any(row[0] == "diagnostic" and row[4] and row[5] for row in health))


def load_tests(loader, tests, pattern):
    return unittest.TestSuite(Step0Tests(name) for name in (
        "test_installed_q0_and_independent_priority_flip",
        "test_installed_qltest_runs_frozen_expected_rows",
        "test_selected_failure_has_health_and_unknown_candidates",
        "test_shared_source_aliases_preserve_target_identity_and_unknown_ambiguous_files",
    ))
