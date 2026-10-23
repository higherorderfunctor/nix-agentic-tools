"""R0 replacement evidence, frozen from the retired F0 contract and golden rows.

Run against the installed coordinator, schema and library, without the disposable
TSV producer or its relation/pack. Expected columns count original UTF-8 bytes.
"""

import os
import subprocess
import unittest

import test_installed


class RetirementTests(test_installed.InstalledTests):
    def test_r0_installed_raw_coordinates(self):
        self.fixture()
        sources = {
            "coordinates.nix": '{\r\n\tunicode = "é"; number = 73;\r\n\tafter = 97;\r\n}\r\n',
            "mismatch.nix": "97\n",
            "recovered.nix": "{\n  broken = ;\n  good = 41;\n}\n",
            "selected.nix": "41\n",
            "unselected.nix": "41\n",
        }
        for name, source in sources.items():
            (self.root / name).write_bytes(source.encode("utf-8"))
        database, _ = self.create()
        rows = self.query(database, "RetiredRawProof", '''import nix.internal.generated.Ast
          from Nix::Token token, string file
          where file = token.getLocation().getFile().getRelativePath() and
            file = ["coordinates.nix", "mismatch.nix", "recovered.nix", "selected.nix", "unselected.nix"] and
            token.getValue() = ["41", "73", "97"] and
            token.getLocation().getFile().getAbsolutePath().matches("%/" + file)
          select file, token.getValue(),
            token.getLocation().getStartLine(), token.getLocation().getStartColumn(),
            token.getLocation().getEndLine(), token.getLocation().getEndColumn()''')
        self.assertCountEqual(rows, [
            ["coordinates.nix", "73", "2", "27", "2", "28"],
            ["coordinates.nix", "97", "3", "10", "3", "11"],
            ["mismatch.nix", "97", "1", "1", "1", "2"],
            ["recovered.nix", "41", "3", "10", "3", "11"],
            ["selected.nix", "41", "1", "1", "1", "2"],
            ["unselected.nix", "41", "1", "1", "1", "2"],
        ])
        print("PASS R0 installed raw proof: six rows, distinct equal-text files, recovered parse, UTF-8/tab/CRLF byte coordinates", flush=True)

    def test_r0_missing_extractor_and_library_refuse(self):
        # The customized installed command supplies these products itself. Its
        # bare engine is the control that can actually lack both products.
        empty = self.scratch / "empty"
        empty.mkdir()
        pack = self.scratch / "missing-library"
        pack.mkdir()
        (pack / "qlpack.yml").write_text('name: nix-agentic-tools/r0-missing-library\nversion: 0.0.0\ndependencies:\n  nix-agentic-tools/nix-all: "*"\n')
        query = pack / "Missing.ql"
        query.write_text("import nix.internal.generated.Ast\nselect 1\n")
        for name, arguments, witness in (
            ("extractor", ["resolve", "extractor", "--language=nix"], "nix"),
            ("library", ["query", "compile", str(query)], "nix-agentic-tools/nix-all"),
        ):
            with self.subTest(name=name):
                command = [os.environ["CODEQL_NIX_TEST_BARE_COMMAND"], *arguments, "--search-path=" + str(empty)]
                if name == "library":
                    command = ["flock", os.environ["CODEQL_NIX_TEST_LOCK"], *command, "--threads=4", "--ram=6000"]
                result = subprocess.run(
                    command,
                    cwd=self.scratch, env=self.env, capture_output=True, text=True, timeout=120,
                )
                self.assertNotEqual(result.returncode, 0, "missing " + name + " unexpectedly resolved")
                self.assertIn(witness, result.stdout + result.stderr)
                if name == "extractor":
                    self.assertIn("extractor", (result.stdout + result.stderr).lower())
                print("PASS R0 missing " + name + " refused with named lookup diagnostic", flush=True)


def load_tests(loader, tests, pattern):
    return unittest.TestSuite(RetirementTests(name) for name in (
        "test_r0_installed_raw_coordinates",
        "test_r0_missing_extractor_and_library_refuse",
    ))
