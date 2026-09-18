#!/usr/bin/env python3
"""Contracts for the view tools' daemon-supplied grammar boundary."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve()
sys.path.insert(0, str(HERE.parents[3] / "dev" / "scripts"))

from scribe_client import ClientError, NoDaemon  # noqa: E402


def load_module(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, HERE.with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


view_check = load_module("view_check_contract", "view-check.py")
wireline = load_module("wireline_contract", "wireline.py")

GRAMMAR_REPLY = {
    "schema": "scribe-grammar/1",
    "types": {
        "WORK": {
            "prefix": "WORK-",
            "fields": [
                {
                    "name": "UID",
                    "kind": "String",
                    "required": True,
                    "options": [],
                }
            ],
            "roles": [],
        }
    },
}


class DaemonGrammarTest(unittest.TestCase):
    def test_validated_reply_is_the_view_grammar(self) -> None:
        root = HERE.parents[3]
        with mock.patch.object(
            view_check, "call_for_root", return_value=GRAMMAR_REPLY
        ) as call:
            grammar = view_check.daemon_grammar(root)
        self.assertEqual(grammar, GRAMMAR_REPLY["types"])
        call.assert_called_once_with(root.resolve(), "workspace.grammar")

    def test_malformed_reply_fails_closed(self) -> None:
        with mock.patch.object(view_check, "call_for_root", return_value={"types": []}):
            with self.assertRaisesRegex(
                ClientError, "invalid workspace.grammar result"
            ):
                view_check.daemon_grammar(HERE.parents[3])

    def test_view_check_prints_the_no_daemon_remedy(self) -> None:
        remedy = "no scribe daemon on fixture.sock.\n  start one with:  devenv up scribe"
        with (
            mock.patch.object(
                view_check, "daemon_grammar", side_effect=NoDaemon(remedy)
            ),
            mock.patch.object(
                sys,
                "argv",
                ["view-check", "missing-index.json", str(HERE.parents[3])],
            ),
            contextlib.redirect_stderr(io.StringIO()) as stderr,
        ):
            self.assertEqual(view_check.main(), 1)
        self.assertIn(remedy, stderr.getvalue())

    def test_wireline_prints_the_no_daemon_remedy(self) -> None:
        remedy = "no scribe daemon on fixture.sock.\n  start one with:  devenv up scribe"
        with (
            mock.patch.object(
                wireline.vc, "daemon_grammar", side_effect=NoDaemon(remedy)
            ),
            mock.patch.object(
                sys,
                "argv",
                ["wireline", "missing-index.json", str(HERE.parents[3])],
            ),
            contextlib.redirect_stderr(io.StringIO()) as stderr,
        ):
            self.assertEqual(wireline.main(), 1)
        self.assertIn(remedy, stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
