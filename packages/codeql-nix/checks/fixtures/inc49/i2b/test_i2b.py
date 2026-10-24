"""I2b frozen contract acceptance; no expectations come from extraction."""
from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

OWNER = Path(__file__).resolve().parents[4]
sys.path[:0] = [str(OWNER / "checks/fixtures/imports"), str(OWNER / "checks/fixtures/abi"), str(OWNER / "checks/fixtures/eval-isolation"), str(OWNER / "schema")]
import abi
import golden
import test_imports as inherited
import test_supervisor as supervisor_fixture
from extract import import_paths

FIXTURE = OWNER / "ql/test/inc49/i2b"
os.environ["NIX_CONFIG"] = "experimental-features ="
PATHS = {"Dep": ["@dep"], "Empty": ["empty"], "Escape": ["escape", "second"],
         "File": ["blocked", "second"], "MissingBoth": ["absent", "also-absent"],
         "MissingFirst": ["absent", "second"], "NoDefault": ["no-default", "second"],
         "S": ["first", "second"], "Swap": ["second", "first"], "Unmapped": []}
MAPPINGS = {name: [{"prefix": "" if name == "Empty" else "pkg",
                   "rootLogicalName": "dep" if path == "@dep" else "project",
                   "relativePath": "" if path == "@dep" else path} for path in paths]
            for name, paths in PATHS.items()}


def tree(root):
    for name, value in {"blocked": 53, "empty/pkg/default.nix": 43, "empty/pkg/sub/default.nix": 47,
                        "first/default.nix": 17, "first/sub/default.nix": 31,
                        "no-default/sub/default.nix": 41, "pkg/default.nix": 17,
                        "second/default.nix": 23, "second/sub/default.nix": 37}.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(str(value) + "\n")
    roots = {"project": str(root), "dep": str(root.parent / "dep")}
    for directory, values in ((Path(roots["dep"]), (61, 67)), (root.parent / "outside", (71, 73))):
        (directory / "sub").mkdir(parents=True)
        (directory / "default.nix").write_text(str(values[0]) + "\n")
        (directory / "sub/default.nix").write_text(str(values[1]) + "\n")
    (root / "escape").symlink_to(root.parent / "outside", target_is_directory=True)
    return roots


class I2bTests(unittest.TestCase):
    def nix(self, *arguments, success=True):
        result = subprocess.run([os.environ.get("CODEQL_NIX_TEST_NIX", "nix"),
            "--extra-experimental-features", "nix-command", *arguments], capture_output=True,
            text=True, env=os.environ | {"NIX_CONFIG": "experimental-features =", "NIX_PATH": "pkg=/nonexistent"}, timeout=30)
        self.assertEqual(result.returncode == 0, success, result.stderr)
        return result.stdout

    def test_independent_nix_search_directory_and_parse_oracles(self):
        with tempfile.TemporaryDirectory(prefix="i2b-oracle-") as temporary:
            root = Path(temporary) / "source"
            root.mkdir()
            roots = tree(root)
            values = {"Dep": (61, 67), "Empty": (43, 47), "Escape": (71, 73), "File": (53, 37),
                      "MissingBoth": (None, None), "MissingFirst": (23, 37), "NoDefault": (None, 41),
                      "S": (17, 31), "Swap": (23, 37), "Unmapped": (None, None)}
            for target, mapping in MAPPINGS.items():
                for name, expected in zip(("pkg", "pkg/sub"), values[target]):
                    with self.subTest(target=target, name=name):
                        args = json.dumps({"roots": roots, "mapping": mapping, "name": name})
                        expression = f'import {Path(__file__).with_name("oracle.nix")} (builtins.fromJSON {json.dumps(args)})'
                        output = self.nix("eval", "--json", "--impure", "--expr", expression, success=expected is not None)
                        if expected is not None:
                            self.assertEqual(json.loads(output), [expected, expected])
            for name, text in {"link/pkg/default.nix": "23", "real/main.nix": "import ./pkg", "real/pkg/default.nix": "17"}.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text)
            (root / "link/main.nix").symlink_to("../real/main.nix")
            file = abi.key("file", [golden.ROOT, "link/main.nix", hashlib.sha256(b"import ./pkg").hexdigest()])
            anchor = abi.key("anchor", [file, "7", "12", "path_expression", "[0,1]"])
            facts = [["nx_files", [file, golden.ROOT, "link/main.nix", hashlib.sha256(b"import ./pkg").hexdigest(), "project"]], ["nx_anchors", [anchor, file, 7, 12, "path_expression", "[0,1]"]]]
            targets = {"T": {"sourceRoots": [{"logicalName": "project", "rootContentIdentity": "content-a"}]}}
            self.assertEqual(import_paths(abi, targets, {golden.ROOT: (root, root)}, facts)[0]["T"], [(anchor, "directory", "resolved", "", (golden.ROOT, "real/pkg/default.nix"))])
            self.assertEqual(json.loads(self.nix("eval", "--json", "--impure", "--file", str((root / "link/main.nix").resolve()))), 17)
            for expected in (17, 53):
                self.assertEqual(json.loads(self.nix("eval", "--json", "--impure", "--expr", f"import {root}/pkg")), expected)
                if expected == 17:
                    (root / "pkg/default.nix").unlink()
                    (root / "pkg").rmdir()
                    (root / "pkg").write_text("53")
            parser = str(Path(os.environ.get("CODEQL_NIX_TEST_NIX", "nix")).with_name("nix-instantiate"))
            command = [parser, "--extra-experimental-features", "nix-command", "--parse", "--expr"]
            parsed = subprocess.run(command + ["import <pkg/sub>"], capture_output=True, text=True, check=True)
            again = subprocess.run(command + [parsed.stdout], capture_output=True, text=True, check=True)
            self.assertEqual(parsed.stdout, again.stdout)
        print("I2b independent Nix ordered search, failure, directory/file and search parse witnesses passed", flush=True)

    def test_abi_candidate_links_and_admission_mutants(self):
        anchor = golden.anchor_key(0, 0, "path_expression", "[0]")
        candidate = ["nx_import_path_candidates", [golden.I["t"], anchor, "directory", "resolved", ""]]
        file = abi.key("file", [golden.ROOT, "target.nix", "content-b"])
        link = ["nx_import_path_targets", [golden.I["t"], anchor, file]]
        base = deepcopy(golden.GRAPH) + [["nx_anchors", [anchor, golden.I["f"], 0, 0, "path_expression", "[0]"]]]
        base += [["nx_files", [file, golden.ROOT, "target.nix", "content-b", "project"]],
                 ["nx_target_inputs", [golden.I["t"], file, "root"]]]
        abi.validate(base + [candidate, link])
        unavailable = ["nx_import_path_candidates", [golden.I["t"], anchor, "search", "unavailable", "missing-input"]]
        for reason in ("missing-input", "search-path-unmapped", "source-not-admitted"):
            unavailable[1][-1] = reason
            abi.validate(base + [unavailable])
        for rows in (base + [candidate], base + [unavailable, link], base + [candidate, link, link],
                     *([row for row in base if row[:1] != ["nx_target_inputs"] or row[1][1] != missing] + [candidate, link]
                       for missing in (golden.I["f"], file))):
            with self.assertRaises(ValueError):
                abi.validate(rows)
        print("I2b ABI resolved/unavailable link cardinality and source admission mutants passed", flush=True)

    def test_ordered_search_identity_and_invalid_descriptor_paths(self):
        fixture = supervisor_fixture.ProjectionCase()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        packet = supervisor_fixture.manifest(fixture.root, [supervisor_fixture.request()])
        target = next(iter(packet["targets"].values()))
        hashes = []
        for mapping in (MAPPINGS["S"], MAPPINGS["Swap"]):
            target["searchPath"] = mapping
            rows = supervisor_fixture.rows(fixture.run_jobs(packet=packet), "nx_targets")
            self.assertEqual(len(rows), 1)
            hashes.append(rows[0][7])
        self.assertNotEqual(*hashes)
        for path in ("../escape", "/absolute", "https://example.invalid/source"):
            target["searchPath"] = [MAPPINGS["S"][0] | {"relativePath": path}]
            self.assertEqual(supervisor_fixture.rows(fixture.run_jobs(packet=packet), "nx_targets"), [])
        print("I2b fast target search-order identity and invalid descriptor paths passed", flush=True)

    def test_installed_directory_and_target_qualified_search_matrix(self):
        for variant in ("D", "S"):
            with self.subTest(variant=variant):
                harness = inherited.ImportTests.installed_harness(self)
                harness.fixture()
                roots = tree(harness.root)
                dependency = Path(roots["dep"])
                nar_hash = self.nix("hash", "path", str(dependency)).strip()
                harness.inputs["dep"] = {"path": str(dependency), "narHash": nar_hash}
                (harness.root / "main.nix").write_text("import ./pkg\n" if variant == "D" else "import <pkg>\n")
                (harness.root / "shadow.nix").write_text("let import = _: 79; in import <pkg>\n")
                if variant == "S":
                    (harness.root / "suffix.nix").write_text("import <pkg/sub>\n")
                target_file = harness.root / ".nixql/targets.nix"
                target_file.rename(target_file.with_name("base.nix"))
                mappings = {"D": []} if variant == "D" else MAPPINGS
                descriptor = json.dumps(json.dumps(mappings))
                target_file.write_text('''{inputs,source}: let original = import ./base.nix {inherit inputs source;};
                  base = builtins.head (builtins.attrValues original.manifest.targets);
                  in original // { manifest = original.manifest // { targets = builtins.mapAttrs
                    (name: searchPath: base // { inherit searchPath; requests = [ (builtins.head base.requests) ];
                      sourceRoots = base.sourceRoots ++ [{logicalName="dep"; path=toString inputs.dep;
                        rootContentIdentity="replaced-by-admission";}]; }) (builtins.fromJSON ''' + descriptor + "); }; }")
                harness.env |= {"NIX_CONFIG": "experimental-features =", "NIX_PATH": "pkg=/nonexistent"}
                database, _ = harness.create()
                rows = harness.installed_query(database, "DirectoryImports")
                expected = [line[2:-2].split(" | ") for line in (FIXTURE / "DirectoryImports.expected").read_text().splitlines()]
                self.assertCountEqual(rows, [row for row in expected if (row[0] == "D") == (variant == "D")])
                if variant == "S":
                    identities = harness.query(database, "SearchIdentity", 'from @nx_target t, string name, string hash where nx_targets(t,_,name,_,_,_,_,hash,_,_) select name,hash')
                    hashes = dict(identities)
                    self.assertNotEqual(hashes["S"], hashes["Swap"])
                    admitted = harness.query(database, "DependencyIdentity", 'from @nx_target t, @nx_file f, string root, string path, string hash where nx_targets(t,_,"Dep",_,_,_,_,_,_,_) and nx_import_path_targets(t,_,f) and nx_files(f,root,path,hash,_) and nx_target_inputs(t,f,_) select root,path,hash')
                    self.assertCountEqual(admitted, [[abi.key("root", ["dep", nar_hash]), name, hashlib.sha256((dependency / name).read_bytes()).hexdigest()] for name in ("default.nix", "sub/default.nix")])
        print("I2b installed DirectoryImports frozen rows, shadow exclusion, policy identity and selected dependency bytes passed", flush=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
