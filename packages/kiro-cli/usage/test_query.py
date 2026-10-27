"""Synthetic calibration queries; no provider, home-directory or log reads."""

import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

import capture
import disk_index
import query


class QueryTests(unittest.TestCase):
    def setUp(self):
        self.db = sqlite3.connect(":memory:")
        self.addCleanup(self.db.close)
        self.db.executescript(capture.SCHEMA + disk_index.SCHEMA)

    def session(self, name, links=None, credits=2):
        path = "/synthetic/workspace/" + name
        self.db.execute("INSERT INTO disk_sessions VALUES (?,?,?,?,?,?,?,?)",
                        (path, "current-model", "session-current", None, None, "{}", "identity", json.dumps(links or {})))
        source = path + "/messages.jsonl"
        self.db.execute("INSERT INTO disk_sources(path,session_path) VALUES (?,?)", (source, path))
        self.db.execute("INSERT INTO disk_records VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                        (source, 0, "usage_summary", None, "execution", "turn", None, 20, "success", json.dumps([{"usage": credits, "unit": "credit"}]), "{}"))
        self.db.execute("INSERT INTO disk_request_ids VALUES (?,?,?,?)", (source, 0, 0, "request-" + name))

    def captured(self, ident, conversation=None, request=None, credits=1, tokens=10, state="complete"):
        meta = {"model": "requested-model"}
        if conversation is not None:
            meta["kiro:conversation_id"] = conversation
        response = {"upstream_request_id": request} if request else {}
        self.db.execute("""INSERT INTO captures(id,metadata_json,response_json,credits,input_tokens,
                        state,completion_seen,issues_json) VALUES (?,?,?,?,?,?,?,?)""",
                        (ident, json.dumps(meta), json.dumps(response), credits, tokens, state,
                         int(state == "complete"), json.dumps([] if state == "complete" else ["transport_error"])))

    def test_session_tree_explicit_lineage_cycles_and_unrelated(self):
        self.session("sess_root", {"parentSessionId": "sess_child"})
        self.session("sess_child", {"parentSessionId": "root"})
        self.session("sess_grand", {"rootSessionId": "sess_root"})
        self.session("sess_unrelated")
        for name in ("root", "child", "grand", "unrelated"):
            self.captured(name, conversation="sess_" + name)
        exact = query.query(self.db, "sess_root")
        tree = query.query(self.db, "sess_root", "tree")
        self.assertEqual(exact["sessions"], ["sess_root"])
        self.assertEqual(exact["captures"]["observations"], 1)
        self.assertEqual(tree["sessions"], ["sess_child", "sess_grand", "sess_root"])
        self.assertEqual(tree["captures"]["observations"], 3)
        self.assertEqual(tree["disk"]["turns"], 3)
        self.assertEqual(exact["attribution"]["own_vs_delegate"], "unavailable")

    def test_request_id_join_and_conversation_deduplicate_capture(self):
        self.session("sess_root")
        self.captured("request-only", request="request-sess_root")
        self.captured("both", conversation="root", request="request-sess_root")
        self.captured("unrelated", request="unrelated")
        result = query.query(self.db, "sess_root")
        self.assertEqual(result["captures"]["observations"], 2)
        self.assertEqual(result["captures"]["metrics"]["credits"]["observed_sum"], 2)
        self.assertEqual(result["disk"]["metrics"]["credits"]["observed_sum"], 2)
        self.assertNotIn("combined_total", result)
        self.assertEqual(result["captures"]["duplicate_upstream_request_ids"],
                         [{"request_id": "request-sess_root", "captures": 2}])
        self.assertTrue(any("ambiguous" in warning for warning in result["warnings"]))

    def test_unknowns_not_zero_and_failed_truncated_captures(self):
        self.session("sess_root", credits=None)
        self.captured("failed", conversation="root", credits=None, tokens=None, state="incomplete")
        self.captured("truncated", conversation="root", credits=0, tokens=0, state="incomplete")
        result = query.query(self.db, "sess_root")
        self.assertEqual(result["captures"]["incomplete"], 2)
        self.assertEqual(result["captures"]["metrics"]["credits"],
                         {"observed_sum": 0, "known": 1, "unknown": 1})
        self.assertEqual(result["captures"]["metrics"]["output_tokens"],
                         {"observed_sum": None, "known": 0, "unknown": 2})
        self.assertEqual(result["disk"]["metrics"]["credits"],
                         {"observed_sum": None, "known": 0, "unknown": 1})
        self.assertEqual(result["disk"]["metrics"]["input_tokens"]["observed_sum"], None)

    def test_empty_and_missing_sources(self):
        result = query.query(self.db, "sess_unknown")
        self.assertIsNone(result["captures"]["metrics"]["credits"]["observed_sum"])
        self.assertIsNone(result["disk"]["metrics"]["credits"]["observed_sum"])
        with sqlite3.connect(":memory:") as empty:
            result = query.query(empty, "sess_unknown")
            self.assertFalse(result["captures"]["available"])
            self.assertFalse(result["disk"]["available"])

    def test_omissions_are_scoped_and_legacy_indexes_remain_queryable(self):
        self.session("sess_root")
        self.session("sess_child", {"parentSessionId": "root"})
        self.session("sess_unrelated")
        for name in ("child", "unrelated"):
            self.db.execute("INSERT INTO disk_omissions VALUES (?,?,?,?)",
                            ("/synthetic/workspace/sess_" + name + "/messages.jsonl", 100,
                             999, "record_exceeds_parse_budget"))
        exact = query.query(self.db, "sess_root")
        self.assertEqual(exact["disk"]["omitted_records"], 0)
        self.assertFalse(any("records were omitted" in warning for warning in exact["warnings"]))
        tree = query.query(self.db, "sess_root", "tree")
        self.assertEqual(tree["disk"]["omitted_records"], 1)
        self.assertTrue(any("usage coverage is unknown" in warning for warning in tree["warnings"]))
        self.db.execute("DROP TABLE disk_omissions")
        legacy = query.query(self.db, "sess_root")
        self.assertIsNone(legacy["disk"]["omitted_records"])
        self.assertFalse(legacy["disk"]["omission_tracking"])
        self.assertEqual(legacy["disk"]["turns"], 1)

    def test_models_are_scoped_to_their_source(self):
        self.session("sess_root")
        self.captured("call", conversation="root")
        result = query.query(self.db, "sess_root")
        model = result["captures"]["models"][0]
        self.assertEqual(model["requested_model"], "requested-model")
        self.assertEqual(model["observations"], 1)
        self.assertEqual(model["metrics"]["input_tokens"], {"observed_sum": 10, "known": 1, "unknown": 0})
        self.assertEqual(result["disk"]["model_scope"], "session-current")
        self.assertEqual(result["disk"]["models"], [{"model_id": "current-model", "sessions": 1}])

    def test_cli_missing_database_is_not_created(self):
        with tempfile.TemporaryDirectory() as temporary:
            missing = Path(temporary) / "absent.sqlite"
            result = subprocess.run([sys.executable, query.__file__, "--db", str(missing),
                                     "--session", "sess_root"], capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertFalse(missing.exists())

    def test_credit_units_partial_turns_and_disk_overlap_ambiguity(self):
        self.session("sess_root")
        self.session("sess_child", {"parentSessionId": "root"})
        self.db.execute("UPDATE disk_records SET usage_json=? WHERE source_path LIKE '%sess_root/%'",
                        (json.dumps([{"usage": 2, "unit": "credit"}, {"usage": None, "unit": "credit"},
                                     {"usage": 900, "unit": "token"}]),))
        self.db.execute("UPDATE disk_request_ids SET request_id='overlapping'")
        result = query.query(self.db, "sess_root", "tree")
        self.assertEqual(result["disk"]["metrics"]["credits"],
                         {"observed_sum": 4, "known": 1, "unknown": 1})
        self.assertEqual(result["disk"]["duplicate_request_ids"],
                         [{"request_id": "overlapping", "occurrences": 2}])
        self.assertTrue(any("not an exact additive" in warning for warning in result["warnings"]))
        self.db.execute("DELETE FROM disk_request_ids")
        result = query.query(self.db, "sess_root")
        self.assertEqual(result["disk"]["turns_without_request_ids"], 1)
        self.assertTrue(any("cannot be checked" in warning for warning in result["warnings"]))

    def test_global_unattributed_coverage_never_infers_session_membership(self):
        self.session("sess_root")
        self.captured("mapped", request="request-sess_root")
        self.captured("unattributed", request="unmapped")
        result = query.query(self.db, "sess_root")
        self.assertEqual(result["captures"]["observations"], 1)
        self.assertEqual(result["captures"]["global_unattributed_observations"], 1)
        self.assertTrue(any("global capture store" in warning for warning in result["warnings"]))
        self.db.execute("DROP TABLE disk_request_ids")
        result = query.query(self.db, "sess_root")
        self.assertEqual(result["captures"]["global_unattributed_observations"], 2)
        self.assertEqual(result["captures"]["observations"], 0)


if __name__ == "__main__":
    unittest.main()
