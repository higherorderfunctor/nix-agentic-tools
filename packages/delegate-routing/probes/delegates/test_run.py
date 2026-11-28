#!/usr/bin/env python3
# cspell:ignore dflt noexcerpt rccap
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
| fake:miss     | `echo CHILD_A child fake-b` (comment `ignored`) | `child fake-b … CHILD_A`                 | OFFLINE |
| fake:absent   | `echo NAMED_BODY`                              | `NAMED_BODY` absent                       | OFFLINE |
| fake:forbidden| `echo CHILD_B`                                 | no `CHILD_B`                              | OFFLINE |
| fake:joined   | `echo` `JOINED`; `… AGAIN`                     | `JOINED`, `AGAIN`; `out.json` is a locator| OFFLINE |
| fake:pipe     | `printf 'a\\|b\\n'`                             | `a\\|b`                                    | OFFLINE |
| fake:live     | `echo LIVE_RAN`                                | `LIVE_RAN`                                | LIVE    |
| fake:prose    | see below                                      | `x`                                       | OFFLINE |
| fake:input    | `cat <work>/x`                                 | `x`                                       | OFFLINE |
| fake:noexcerpt| `echo hi`                                      | prints hi                                 | OFFLINE |
| fake:rc1      | `echo RC_OUT; false`                           | `RC_OUT`                                  | OFFLINE |
| fake:rccap    | `false \\|\\| echo rc=$?`                      | `rc=1`                                    | OFFLINE |
| fake:slow     | `echo SLOW_OUT; sleep 5`                       | `SLOW_OUT`                                | OFFLINE |
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

    def test_list_and_only(self):
        # Pin qualified prefixes, bare ids, command continuations, and section defaults.
        code, out = self.main("--list", "--only=fake/fake:m*,dflt-1,fake:joined")
        self.assertEqual(code, 0)
        self.assertEqual(
            out.splitlines(),
            [
                "fake/fake:match\trunnable\tprintf 'child fake-b high x CHILD_A\\n'",
                "fake/fake:miss\trunnable\techo CHILD_A child fake-b",
                "fake/fake:joined\trunnable\techo JOINED ; echo AGAIN",
                "fake/dflt-1\trunnable\techo dflt-1",
            ],
        )
        self.assertFalse((Path(self.tmp.name) / "out").exists())

    def test_unmatched_selection_reports_usage_error(self):
        err = io.StringIO()
        with redirect_stderr(err), self.assertRaises(SystemExit) as raised:
            self.main("--list", "--only=nope")
        self.assertEqual(raised.exception.code, 2)
        self.assertIn("--only matched nothing: nope", err.getvalue())
        self.assertNotIn("Traceback", err.getvalue())

    def test_run_verdicts(self):
        code, out = self.main("--timeout=2")
        expected = {
            "dflt-1": ("MATCH", ""),  # Execute the default when there is no command column.
            "fake:a": ("MATCH", ""),  # Retain the first ID in a shared row.
            "fake:b": ("MATCH", ""),  # Retain the second ID in a shared row.
            "fake:joined": ("MATCH", ""),  # Don't require the locator in output.
            "fake:match": ("MATCH", ""),  # Accept intervening text in ordered fragments.
            "fake:pipe": ("MATCH", ""),  # Don't split a cell at an escaped pipe.
            "fake:rccap": ("MATCH", ""),  # Accept a shell failure handled in the command.
            # Both absence spellings reject forbidden output. Reversed fragments
            # don't match. Seeing the right text does not excuse failure or timeout.
            "fake:absent": ("MISMATCH", "unexpected ['NAMED_BODY']"),
            "fake:forbidden": ("MISMATCH", "unexpected ['CHILD_B']"),
            "fake:miss": ("MISMATCH", "missing ['child fake-b … CHILD_A']"),
            "fake:rc1": ("MISMATCH", "exit 1"),
            "fake:slow": ("MISMATCH", "timeout 2s"),
            # Skip unresolved commands, unapproved live runs, and prose cells.
            "fake:input": ("SKIP", "command needs input: <work>"),
            "fake:live": ("SKIP", "LIVE (pass --live)"),
            "fake:noexcerpt": ("SKIP", "no backtick literal"),
            "fake:prose": ("SKIP", "no runnable command (prose cell"),
        }
        rows = [
            line.split(maxsplit=2)
            for line in out.splitlines()
            if line.startswith(("MATCH", "MISMATCH", "SKIP"))
        ]
        self.assertCountEqual([qid for _, qid, _ in rows], [f"fake/{case}" for case in expected])
        for verdict, qid, detail in rows:
            with self.subTest(case=qid):
                expected_verdict, reason = expected[qid.removeprefix("fake/")]
                self.assertEqual(verdict, expected_verdict)
                if reason:
                    self.assertIn(reason, detail)
        self.assertEqual(code, 5)

    def test_live_opt_in_runs_selected_case(self):
        code, out = self.main("--only=fake:live", "--live")
        self.assertEqual(code, 0)
        self.assertTrue(out.startswith("MATCH     fake/fake:live  "), out)


if __name__ == "__main__":
    unittest.main()
