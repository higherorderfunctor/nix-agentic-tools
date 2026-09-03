#!/usr/bin/env python3
"""Contracts for the adapter and the read-only HTTP boundary.

Hermetic on purpose: the adapter is fed a fixture export, and the server a
fake source, so the suite runs under any python3 with no daemon and no
strictdoc. The live path (daemon -> export -> adapt -> serve) is exercised
by hand against the resident scribe; EV-SDOC-BOARD-MERGED-SMOKE records one
such run.
"""

from __future__ import annotations

import json
import threading
import unittest
import urllib.error
import urllib.request
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from adapter import REPO_ROOT, ROWS_SCHEMA, SNAPSHOT_SCHEMA, adapt
from server import build_server
from source import NoDaemon, Payloads

FIXTURE_INDEX = {
    "_COMMENT": "fixture",
    "DOCUMENTS": [
        {
            "_NODE_TYPE": "DOCUMENT",
            "TITLE": "A decision",
            "GRAMMAR": [],
            "NODES": [
                {
                    "_TOC": "1",
                    "_NODE_TYPE": "DECISION",
                    "UID": "DEC-FIX-ONE",
                    "TITLE": "A decision",
                    "AUTHORED_BY": "llm",
                    "STATUS": "accepted",
                    "STATEMENT": "One choice.",
                }
            ],
        },
        {
            "_NODE_TYPE": "DOCUMENT",
            "TITLE": "A mechanism",
            "GRAMMAR": [],
            "NODES": [
                {
                    "_TOC": "1",
                    "_NODE_TYPE": "MECHANISM",
                    "UID": "MECH-FIX-TWO",
                    "TITLE": "A mechanism",
                    "AUTHORED_BY": "llm",
                    "DEPTH": "sketch",
                    "STATEMENT": "How it behaves.",
                    "RELATIONS": [
                        {"TYPE": "Parent", "VALUE": "DEC-FIX-ONE", "ROLE": "Governed_By"},
                        {"TYPE": "Parent", "VALUE": "DEC-FIX-GONE", "ROLE": "Governed_By"},
                        {"TYPE": "File", "VALUE": "docs/sdoc/board/server.py"},
                        # The same file again, named down to one item in it.
                        # Two relations, ONE file: the pair is what proves
                        # FILE_COUNT counts files rather than relations.
                        {
                            "TYPE": "File",
                            "VALUE": "docs/sdoc/board/server.py",
                            "ELEMENT": "function",
                            "ID": "build_server",
                            "LINE_RANGE": "40, 52",
                        },
                    ],
                }
            ],
        },
    ],
}
FIXTURE_PATHS = {
    "DEC-FIX-ONE": "docs/plans/fixture/dec-fix-one.sdoc",
    "MECH-FIX-TWO": "docs/plans/fixture/mech-fix-two.sdoc",
}
FIXTURE_GRAMMAR = {
    "DECISION": {"prefix": "DEC-", "fields": [], "roles": []},
    "MECHANISM": {"prefix": "MECH-", "fields": [], "roles": []},
}
FIXTURE_PROJECT = {"name": "fixture", "root": "/fixture", "generation": 7}

# The one real file this suite touches, and a committed FIXTURE rather than a
# corpus file: dev/scripts/test_sdoc_extractors.py asserts the same ids
# against the same bytes, so the two suites move together or not at all.
NIX_FIXTURE_PATH = "dev/scripts/sdoc_extractors/fixtures/mod.nix"


def adapted():
    return adapt(FIXTURE_INDEX, FIXTURE_PATHS, FIXTURE_GRAMMAR, FIXTURE_PROJECT)


class AdapterContractTest(unittest.TestCase):
    def test_snapshot_resolves_edges_and_reports_the_dangling_one(self) -> None:
        snapshot = adapted()["snapshot"]
        self.assertEqual(snapshot["schema"], SNAPSHOT_SCHEMA)
        self.assertEqual(snapshot["stats"]["nodes"], 2)
        self.assertEqual(snapshot["stats"]["edges"], 1)
        self.assertEqual(
            snapshot["edges"][0],
            {
                "id": "MECH-FIX-TWO:DEC-FIX-ONE:Parent:Governed_By:0",
                "source": "MECH-FIX-TWO",
                "target": "DEC-FIX-ONE",
                "type": "Parent",
                "role": "Governed_By",
            },
        )
        self.assertEqual(
            [d["kind"] for d in snapshot["diagnostics"]], ["unresolved-relation"]
        )
        self.assertEqual(snapshot["diagnostics"][0]["target"], "DEC-FIX-GONE")

    def test_snapshot_nodes_carry_state_path_and_files(self) -> None:
        snapshot = adapted()["snapshot"]
        by_id = {node["id"]: node for node in snapshot["nodes"]}
        decision = by_id["DEC-FIX-ONE"]
        mechanism = by_id["MECH-FIX-TWO"]
        self.assertEqual(decision["state"], {"field": "STATUS", "value": "accepted"})
        self.assertEqual(mechanism["state"], {"field": "DEPTH", "value": "sketch"})
        self.assertEqual(
            mechanism["source"]["path"], "docs/plans/fixture/mech-fix-two.sdoc"
        )
        self.assertEqual(mechanism["files"], ["docs/sdoc/board/server.py"])
        self.assertNotIn("RELATIONS", mechanism["fields"])
        self.assertNotIn("_NODE_TYPE", mechanism["fields"])

    def test_snapshot_carries_the_item_a_file_relation_names(self) -> None:
        """`files` stays the plain paths every sdoc-board/2 reader expects;
        the element-grained view arrives beside it, one entry per RELATION."""
        by_id = {node["id"]: node for node in adapted()["snapshot"]["nodes"]}
        mechanism = by_id["MECH-FIX-TWO"]
        self.assertEqual(
            mechanism["fileRelations"],
            [
                # The whole-file relation sorts ahead of the item-grained
                # one: they share a path, and an absent id sorts first.
                {
                    "path": "docs/sdoc/board/server.py",
                    "element": None,
                    "kind": None,
                    "id": None,
                    "lineRange": None,
                },
                {
                    "path": "docs/sdoc/board/server.py",
                    "element": "function",
                    # NULL, and that is the contract rather than an omission:
                    # no configured glob covers a `.py` file, so nothing
                    # parses it and there is no kind to report. The card
                    # falls back to ELEMENT. That is element-check's finding
                    # to make -- never a reason for the adapter to fail.
                    "kind": None,
                    "id": "build_server",
                    "lineRange": "40, 52",
                },
            ],
        )
        self.assertEqual(by_id["DEC-FIX-ONE"]["fileRelations"], [])

    def test_kind_is_resolved_when_the_extractor_is_available(self) -> None:
        """The KIND word the export does not carry.

        ELEMENT is strictdoc's closed vocabulary, so an option and a plain
        binding both export as `function` and the card drew them alike. The
        kind comes from resolving the id against the file, and this asserts
        the two DISAGREE on a real item -- `option` against `function` --
        because a test where they happened to match would pass just as well
        against an adapter that merely echoed ELEMENT back.

        Skipped, not failed, where the extractor cannot run: this suite is
        meant to run under any python3, and the adapter's soft import is the
        mechanism that keeps that true.

        THE SKIP PREDICATE IS A REAL EXTRACTION, NOT AN IMPORT, and the
        difference is measured. `import sdoc_extractors.registry` SUCCEEDS
        under this dev shell's plain `python3` -- `tree_sitter` is on its
        path -- while `SDOC_TS_NIX_PARSER` is set only on the
        strictdoc-grammar-extract wrapper, so the grammar load fails later.
        An importability guard therefore lets the test through on an
        interpreter that cannot resolve anything, and it fails with a bare
        `None != 'option'` that reads like an adapter bug.
        """
        try:
            from sdoc_extractors import registry

            registry.items_of(
                REPO_ROOT / NIX_FIXTURE_PATH, path_root=REPO_ROOT
            )
        except Exception as error:  # noqa: BLE001 - any failure is a skip
            self.skipTest(f"no working source extractor here: {error}")
        index = json.loads(json.dumps(FIXTURE_INDEX))
        relations = index["DOCUMENTS"][1]["NODES"][0]["RELATIONS"]
        relations[-1] = {
            "TYPE": "File",
            "VALUE": NIX_FIXTURE_PATH,
            "ELEMENT": "function",
            "ID": "options.services.foo.port",
        }
        payloads = adapt(
            index,
            FIXTURE_PATHS,
            FIXTURE_GRAMMAR,
            FIXTURE_PROJECT,
            source_root=REPO_ROOT,
        )
        by_id = {node["id"]: node for node in payloads["snapshot"]["nodes"]}
        item = next(
            relation
            for relation in by_id["MECH-FIX-TWO"]["fileRelations"]
            if relation["id"]
        )
        self.assertEqual(item["kind"], "option")
        self.assertEqual(item["element"], "function")
        row = next(
            r
            for r in payloads["rows"]["relations"]
            if r["ELEMENT_ID"] == "options.services.foo.port"
        )
        self.assertEqual(row["ELEMENT_KIND"], "option")

    def test_rows_share_one_key_set_per_table(self) -> None:
        rows = adapted()["rows"]
        self.assertEqual(rows["schema"], ROWS_SCHEMA)
        node_keys = [tuple(row.keys()) for row in rows["nodes"]]
        self.assertEqual(len(set(node_keys)), 1)
        relation_keys = [tuple(row.keys()) for row in rows["relations"]]
        self.assertEqual(len(set(relation_keys)), 1)
        # STATUS exists only on the DECISION; the MECHANISM row must still
        # carry the key (null), or Perspective would drop the column.
        mech_row = next(r for r in rows["nodes"] if r["UID"] == "MECH-FIX-TWO")
        self.assertIn("STATUS", mech_row)
        self.assertIsNone(mech_row["STATUS"])

    def test_relations_table_is_one_denormalized_row_per_declaration(self) -> None:
        rows = adapted()["rows"]["relations"]
        self.assertEqual(len(rows), 4)  # resolved + dangling + two File
        resolved = next(r for r in rows if r["TARGET"] == "DEC-FIX-ONE")
        self.assertEqual(resolved["SOURCE_TYPE"], "MECHANISM")
        self.assertEqual(resolved["ROLE"], "Governed_By")
        self.assertEqual(resolved["TARGET_TYPE"], "DECISION")
        self.assertEqual(resolved["TARGET_TITLE"], "A decision")
        self.assertEqual(resolved["TARGET_STATE"], "accepted")
        self.assertTrue(resolved["RESOLVED"])
        dangling = next(r for r in rows if r["TARGET"] == "DEC-FIX-GONE")
        self.assertFalse(dangling["RESOLVED"])
        self.assertIsNone(dangling["TARGET_TYPE"])
        file_rows = [r for r in rows if r["TYPE"] == "File"]
        self.assertEqual(
            [r["TARGET"] for r in file_rows], ["docs/sdoc/board/server.py"] * 2
        )
        # The columns exist on EVERY row, not only where a File relation
        # fills them: Perspective infers its schema from the row list, and a
        # key that first appears late never becomes a column.
        for row in rows:
            self.assertIn("ELEMENT", row)
            self.assertIn("ELEMENT_KIND", row)
            self.assertIn("ELEMENT_ID", row)
            self.assertIn("LINE_RANGE", row)
        self.assertIsNone(resolved["ELEMENT"])
        item_row = next(r for r in file_rows if r["ELEMENT"] is not None)
        self.assertEqual(item_row["ELEMENT"], "function")
        self.assertEqual(item_row["ELEMENT_ID"], "build_server")
        self.assertEqual(item_row["LINE_RANGE"], "40, 52")

    def test_counts_come_from_resolved_edges_only(self) -> None:
        rows = adapted()["rows"]["nodes"]
        by_uid = {row["UID"]: row for row in rows}
        self.assertEqual(by_uid["MECH-FIX-TWO"]["OUT_COUNT"], 1)
        self.assertEqual(by_uid["MECH-FIX-TWO"]["FILE_COUNT"], 1)
        self.assertEqual(by_uid["DEC-FIX-ONE"]["IN_COUNT"], 1)


class FakeSource:
    """Duck-typed DaemonSource: canned payloads, or a canned refusal."""

    def __init__(self, refuse: Exception | None = None) -> None:
        self.refuse = refuse
        body = adapted()
        self.canned = Payloads(
            generation=FIXTURE_PROJECT["generation"],
            snapshot=json.dumps(body["snapshot"]).encode("utf-8"),
            rows=json.dumps(body["rows"]).encode("utf-8"),
        )

    def describe(self) -> dict:
        if self.refuse is not None:
            raise self.refuse
        return {"root": "/fixture", "generation": 7, "dirty": False, "nodes": 2}

    def payloads(self) -> Payloads:
        if self.refuse is not None:
            raise self.refuse
        return self.canned


class ServerContractTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = build_server(FakeSource(), "127.0.0.1", 0)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        host, port = cls.server.server_address[:2]
        cls.base_url = f"http://{host}:{port}"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)

    def test_api_routes_serve_both_payloads_and_health(self) -> None:
        with urllib.request.urlopen(f"{self.base_url}/api/graph") as response:
            self.assertEqual(response.status, 200)
            self.assertEqual(json.load(response)["schema"], SNAPSHOT_SCHEMA)
        with urllib.request.urlopen(f"{self.base_url}/api/rows") as response:
            self.assertEqual(json.load(response)["schema"], ROWS_SCHEMA)
        with urllib.request.urlopen(f"{self.base_url}/api/health") as response:
            health = json.load(response)
        self.assertTrue(health["ok"])
        self.assertEqual(health["generation"], 7)

    def test_static_routes_are_allowlisted(self) -> None:
        with urllib.request.urlopen(f"{self.base_url}/") as response:
            self.assertIn(b"SDOC BOARD", response.read())
        for leaked in ("/server.py", "/source.py", "/adapter.py", "/test_board.py"):
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(f"{self.base_url}{leaked}")
            self.assertEqual(error.exception.code, 404)
            error.exception.close()

    def test_mutating_methods_are_rejected(self) -> None:
        request = urllib.request.Request(
            f"{self.base_url}/api/graph", data=b"{}", method="POST"
        )
        with self.assertRaises(urllib.error.HTTPError) as error:
            urllib.request.urlopen(request)
        self.assertEqual(error.exception.code, 405)
        self.assertEqual(error.exception.headers["Allow"], "GET, HEAD")
        error.exception.close()

    def test_no_daemon_is_a_503_carrying_the_remedy(self) -> None:
        refusing = build_server(
            FakeSource(refuse=NoDaemon("no scribe daemon on /some.sock.\n  start one with:  devenv up scribe")),
            "127.0.0.1",
            0,
        )
        thread = threading.Thread(target=refusing.serve_forever, daemon=True)
        thread.start()
        host, port = refusing.server_address[:2]
        try:
            with self.assertRaises(urllib.error.HTTPError) as error:
                urllib.request.urlopen(f"http://{host}:{port}/api/graph")
            self.assertEqual(error.exception.code, 503)
            body = json.load(error.exception)
            error.exception.close()
            self.assertEqual(body["error"], "no-daemon")
            self.assertIn("devenv up scribe", body["detail"])
        finally:
            refusing.shutdown()
            refusing.server_close()
            thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
