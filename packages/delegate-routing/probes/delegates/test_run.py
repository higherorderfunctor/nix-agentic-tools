#!/usr/bin/env python3
"""Offline tests for run.py: a synthetic harness README, no probe is started."""

from contextlib import redirect_stderr, redirect_stdout
import io
from pathlib import Path
import tempfile
import unittest

import run

README = """# Fake harness

## Cases

| Case id       | Command                                        | Expected excerpt                          | Kind    |
| ------------- | ---------------------------------------------- | ----------------------------------------- | ------- |
| fake:match    | `printf 'child fake-b high x CHILD_A\\n'`       | `child fake-b … CHILD_A`; no `CHILD_B`    | OFFLINE |
| fake:miss     | `echo one` (comment `ignored`)                 | `two`                                     | OFFLINE |
| fake:absent   | `echo NAMEDBODY`                               | `NAMEDBODY` absent                        | OFFLINE |
| fake:joined   | `echo` `JOINED`; `… AGAIN`                     | `JOINED`, `AGAIN`; `out.json` is a locator| OFFLINE |
| fake:pipe     | `printf 'a\\|b\\n'`                             | `a\\|b`                                    | OFFLINE |
| fake:live     | `echo LIVE_RAN`                                | `LIVE_RAN`                                | LIVE    |
| fake:prose    | see below                                      | `x`                                       | OFFLINE |
| fake:input    | `cat <work>/x`                                 | `x`                                       | OFFLINE |
| fake:noexcerpt| `echo hi`                                      | prints hi                                 | OFFLINE |
| fake:a / fake:b | `echo SHARED`                                | `SHARED`                                  | OFFLINE |

### Section defaults

| Id     | Expected excerpt |
| ------ | ---------------- |
| dflt-1 | `dflt-1`         |
"""


class Runner(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "probes"
        (self.root / "fake").mkdir(parents=True)
        (self.root / "fake/README.md").write_text(README)
        self.defaults = dict(run.SECTION_DEFAULTS)
        run.SECTION_DEFAULTS[("fake", "Section defaults")] = "echo {id}"

    def tearDown(self):
        run.SECTION_DEFAULTS.clear()
        run.SECTION_DEFAULTS.update(self.defaults)
        self.tmp.cleanup()

    def main(self, *argv):
        out = io.StringIO()
        with redirect_stdout(out):
            code = run.main(["--root", str(self.root), "--out", str(Path(self.tmp.name) / "out"), *argv])
        return code, out.getvalue()

    def test_discovery(self):
        cases = {case.qid: case for case in run.discover(self.root)}
        self.assertEqual(cases["fake/fake:joined"].commands, ["echo JOINED", "echo AGAIN"])
        self.assertEqual(cases["fake/fake:miss"].commands, ["echo one"])
        self.assertEqual(cases["fake/fake:match"].needles, [(["child fake-b", "CHILD_A"], True), (["CHILD_B"], False)])
        self.assertEqual(cases["fake/fake:joined"].needles, [(["JOINED"], True), (["AGAIN"], True)])
        self.assertTrue(cases["fake/fake:live"].live)
        self.assertIn("prose", cases["fake/fake:prose"].skip)
        self.assertIn("<work>", cases["fake/fake:input"].skip)
        self.assertIn("no backtick literal", cases["fake/fake:noexcerpt"].skip)
        self.assertIn("fake/fake:a", cases)
        self.assertIn("fake/fake:b", cases)
        self.assertEqual(cases["fake/dflt-1"].commands, ["echo dflt-1"])

    def test_list_and_only(self):
        code, out = self.main("--list", "--only=fake/fake:m*,dflt-1")
        self.assertEqual(code, 0)
        self.assertEqual([line.split("\t")[0] for line in out.splitlines()], ["fake/fake:match", "fake/fake:miss", "fake/dflt-1"])
        err = io.StringIO()
        with redirect_stderr(err), self.assertRaises(SystemExit) as raised:
            self.main("--list", "--only=nope")
        self.assertEqual(raised.exception.code, 2)
        self.assertIn("--only matched nothing: nope", err.getvalue())
        self.assertNotIn("Traceback", err.getvalue())

    def test_run_counts_mismatches(self):
        code, out = self.main()
        verdicts = {line.split()[1]: line.split()[0] for line in out.splitlines() if line.startswith(("MATCH", "MISMATCH", "SKIP"))}
        self.assertEqual(verdicts["fake/fake:match"], "MATCH")
        self.assertEqual(verdicts["fake/fake:miss"], "MISMATCH")
        self.assertEqual(verdicts["fake/fake:absent"], "MISMATCH")
        self.assertEqual(verdicts["fake/fake:joined"], "MATCH")
        self.assertEqual(verdicts["fake/fake:pipe"], "MATCH")
        self.assertEqual(verdicts["fake/fake:live"], "SKIP")
        self.assertEqual(verdicts["fake/dflt-1"], "MATCH")
        self.assertEqual(code, 2)
        self.assertIn("missing ['two']", out)
        code, out = self.main("--only=fake:live", "--live")
        self.assertEqual((code, out.split()[0]), (0, "MATCH"))


if __name__ == "__main__":
    unittest.main()
