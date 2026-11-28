"""Synthetic calibration queries; no provider, home-directory or log reads."""
# cspell:words tzset

from contextlib import closing
from datetime import datetime
import functools
import io
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import capture
import disk_index
import query
import report
import store

OPUS = "claude-opus-5.5"
# Synthetic schedule: 30,000 input tokens cost .10 credits on a full hit or .40 on a full miss.
RATES = {"chars_per_token": 4, "fixed_per_call": .01, "hit_input": .000003,
         "miss_input": .000013, "output": .001}


class SealedReports:
    """Every report a test reads is read again from a copy of its store with every finished capture sealed, in a
    sealed subTest, and must be equal; a store without the staged tables has nothing to seal and is not copied."""
    REPORTS = ((query, "query"), (query, "run_report"), (report, "store_report"))

    def setUp(self):
        super().setUp()
        for module, name in self.REPORTS:
            patcher = patch.object(module, name, functools.partial(self.compared, name, getattr(module, name)))
            patcher.start()
            self.addCleanup(patcher.stop)

    def compared(self, name, read, db, *args, **options):
        # Imaged before the read, which may see a capture another connection commits while it runs. A backup would
        # wait on the test's open write transaction, and a WAL file's image deserializes read-only unless marked
        # rollback-journal.
        image = bytearray(db.serialize()) if {"chunks", "events", "sealed_responses"} <= store.tables(db) else None
        result = read(db, *args, **options)
        if image:
            image[18:20] = b"\x01\x01"
            with closing(sqlite3.connect(":memory:")) as sealed, self.subTest(sealed=name):
                sealed.deserialize(image)
                sealed.executescript("DELETE FROM capture_meta; INSERT INTO capture_meta VALUES (2);")
                cache = store.RequestCache()
                for (ident,) in sealed.execute("SELECT id FROM captures WHERE state!='recording' ORDER BY started_utc_ns,id").fetchall():
                    store.seal(sealed, ident, cache)
                self.assertEqual(read(sealed, *args, **options), result)
        return result


class QueryTests(SealedReports, unittest.TestCase):
    def setUp(self):
        super().setUp()
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

    def captured(self, ident, conversation=None, request=None, credits=1, tokens=10, state="complete", metadata=None):
        meta = {"model": "requested-model", **(metadata or {})}
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

    def test_session_tree_follows_workflow_root_and_owner(self):
        self.session("sess_root")
        self.session("sess_step", {"rootConversationId": "sess_root", "role": "workflow-step"})
        self.session("sess_owned", {"ownerSessionId": "step"})
        self.session("sess_unrelated", {"rootConversationId": "sess_other", "workflowId": "sess_root"})
        tree = query.query(self.db, "sess_root", "tree")
        self.assertEqual(tree["sessions"], ["sess_owned", "sess_root", "sess_step"])

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

    def test_initialized_sources_without_rows_have_unknown_credits(self):
        result = query.query(self.db, "sess_unknown")
        self.assertIsNone(result["captures"]["metrics"]["credits"]["observed_sum"])
        self.assertIsNone(result["disk"]["metrics"]["credits"]["observed_sum"])

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

    def test_global_metadata_omissions_leave_capture_totals_and_repair_visible(self):
        self.session("sess_root")
        self.captured("root", conversation="root", credits=1)
        self.captured("child", conversation="child", credits=2,
                      metadata={"kiro:root_conversation_id": "root"})
        for session in ("root", "child"):
            self.db.execute("INSERT INTO disk_session_omissions VALUES (?,?)",
                            ("/synthetic/workspace/sess_" + session, "invalid_session_metadata"))
        self.db.execute("DELETE FROM disk_sessions")
        report = query.query(self.db, "sess_root", "tree")
        self.assertEqual(report["disk"]["metadata_omitted_sessions"], 2)
        self.assertTrue(report["disk"]["metadata_omission_tracking"])
        self.assertEqual(report["captures"]["metrics"]["credits"]["observed_sum"], 3)
        self.assertTrue(any("descendant discovery may be incomplete" in warning for warning in report["warnings"]))
        self.assertIn("Session metadata omissions (global): 2", query.render(report))
        # A successful metadata re-index retires these omission entries.
        self.db.execute("DELETE FROM disk_session_omissions")
        repaired = query.query(self.db, "sess_root", "tree")
        self.assertEqual(repaired["disk"]["metadata_omitted_sessions"], 0)
        self.assertFalse(any("descendant discovery may be incomplete" in warning for warning in repaired["warnings"]))
        self.db.execute("DROP TABLE disk_session_omissions")
        legacy = query.query(self.db, "sess_root", "tree")
        self.assertIsNone(legacy["disk"]["metadata_omitted_sessions"])
        self.assertFalse(legacy["disk"]["metadata_omission_tracking"])
        self.assertIn("Session metadata omissions (global): —", query.render(legacy))

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

    def test_wire_root_tree_without_index_and_aliases(self):
        self.db.executescript("DROP TABLE disk_request_ids; DROP TABLE disk_records; DROP TABLE disk_sources; DROP TABLE disk_sessions;")
        self.captured("root", conversation="root", credits=2,
                      metadata={"kiro:root_conversation_id": "sess_root"})
        self.captured("child", conversation="child", credits=3,
                      metadata={"kiro:root_conversation_id": "root"})
        self.captured("root-only", credits=4, metadata={"kiro:root_conversation_id": "root"})
        self.captured("unrelated", conversation="other", credits=100,
                      metadata={"kiro:root_conversation_id": "other"})
        exact = query.query(self.db, "sess_root")
        tree = query.query(self.db, "sess_root", "tree")
        self.assertEqual(exact["captures"]["observations"], 1)
        self.assertEqual(tree["captures"]["observations"], 3)
        self.assertEqual(tree["captures"]["metrics"]["credits"], {"observed_sum": 9, "known": 3, "unknown": 0})
        self.assertEqual(tree["sessions"], ["sess_child", "sess_root"])
        self.assertFalse(tree["disk"]["available"])
        self.assertEqual(tree["captures"]["global_unattributed_observations"], 0)
        self.assertFalse(any("global capture store" in warning for warning in tree["warnings"]))
        # Conversation partition does not infer main versus delegate caller roles.
        for pool, credits in (("root_conversation", 2), ("other_linked_conversations", 3), ("unknown", 4)):
            self.assertEqual(tree["captures"]["pools"][pool]["observations"], 1)
            self.assertEqual(tree["captures"]["pools"][pool]["metrics"]["credits"]["observed_sum"], credits)
        self.captured("truly-unattributed", credits=99)
        mixed = query.query(self.db, "sess_root", "tree")
        self.assertEqual(mixed["captures"]["global_unattributed_observations"], 1)
        self.assertEqual(mixed["captures"]["pools"]["unknown"]["observations"], 1)
        self.assertTrue(any("root-conversation lineage" in warning for warning in mixed["warnings"]))

    def test_conversation_partition_normalizes_root_and_keeps_partial_zero(self):
        self.session("sess_root", credits=50)
        self.captured("prefixed", conversation="sess_root", credits=0)
        self.captured("bare", conversation="root", credits=None)
        self.captured("other", conversation="other", credits=2,
                      metadata={"kiro:root_conversation_id": "root"})
        self.captured("request-only", request="request-sess_root", credits=3)
        report = query.query(self.db, "sess_root", "tree")
        pools = report["captures"]["pools"]
        self.assertEqual(pools["root_conversation"]["metrics"]["credits"],
                         {"observed_sum": 0, "known": 1, "unknown": 1})
        self.assertEqual(pools["other_linked_conversations"]["metrics"]["credits"]["observed_sum"], 2)
        self.assertEqual(pools["unknown"]["metrics"]["credits"]["observed_sum"], 3)
        self.assertEqual(report["captures"]["metrics"]["credits"]["observed_sum"], 5)
        self.assertRegex(query.render(report), r"Root conversation\s+2.*0.000000 \(1/2\)")
        summary = query.render_summary(report)
        self.assertEqual([line.split()[:3] for line in summary.splitlines()[6:12]],
                         [["Main", "2", "0.00"], ["Sub/WF", "1", "2.00"], ["Unknown", "1", "3.00"], ["-" * 62], ["Total", "4", "5.00"], ["⚠", "credits", "unknown"]])
        self.assertIn("does not identify main versus delegate roles", report["attribution"]["pool_rule"])

    def test_tree_membership_paths_overlap_without_counting_capture_twice(self):
        self.session("sess_root", credits=100)
        self.session("sess_child", {"parentSessionId": "root"}, credits=100)
        self.captured("both", conversation="child", request="request-sess_child", credits=1,
                      metadata={"kiro:root_conversation_id": "root"})
        self.captured("duplicate-upstream", conversation="root", request="request-sess_child", credits=2)
        report = query.query(self.db, "sess_root", "tree")
        self.assertEqual(report["captures"]["observations"], 2)
        self.assertEqual(report["captures"]["metrics"]["credits"]["observed_sum"], 3)
        self.assertEqual(report["disk"]["metrics"]["credits"]["observed_sum"], 200)
        self.assertEqual(report["captures"]["duplicate_upstream_request_ids"],
                         [{"request_id": "request-sess_child", "captures": 2}])
        self.assertTrue(any("ambiguous" in warning for warning in report["warnings"]))
        self.assertNotIn("200.00", query.render_summary(report))
        self.assertTrue(query.render_summary(report).endswith("\n⚠ tokens missing for 2; 1 duplicate request ID"))
        self.captured("request-only", request="request-sess_root", credits=4)
        self.captured("no-identity", credits=99)
        report = query.query(self.db, "sess_root", "tree")
        self.assertEqual(report["captures"]["observations"], 3)
        self.assertEqual(report["captures"]["pools"]["unknown"]["metrics"]["credits"]["observed_sum"], 4)

    def test_compact_summary_large_tree_partial_unknown_and_exact_zero(self):
        for index in range(1000):
            self.captured(str(index), conversation=f"child{index}", credits=.5,
                          metadata={"kiro:root_conversation_id": "root"})
        self.captured("missing", conversation="root", credits=None, tokens=None, state="incomplete")
        report = query.query(self.db, "sess_root", "tree")
        self.assertEqual(report["captures"]["pools"]["other_linked_conversations"]["metrics"]["credits"],
                         {"observed_sum": 500, "known": 1000, "unknown": 0})
        output = query.render(report)
        self.assertRegex(output, r"Total\s+1,001\s+—\s+10,000 \(1000/1001\)\s+—\s+—\s+—\s+500.000000 \(1000/1001\)")
        self.assertRegex(output, r"Root conversation\s+1\s+—\s+—\s+—\s+—\s+—\s+—")
        output = query.render_summary(report)
        self.assertTrue(output.startswith("Kiro usage · sess_root · tree · 1,001 requests · 500.00 credits\n"))
        self.assertRegex(output, r"\nrequested-model\s+1,001\s+500.00\s+10.0K\s+—\s+—\s+—\n")
        self.assertRegex(output, r"\nTotal\s+1,001\s+500.00\s+10.0K\s+—\s+—\s+—\n")
        self.assertTrue(output.endswith("⚠ credits unknown for 1/1,001 requests; 1 incomplete; tokens missing for 1,001"))
        self.db.execute("DELETE FROM captures")
        self.captured("zero", conversation="root", credits=0, tokens=0)
        self.db.execute("UPDATE captures SET output_tokens=0 WHERE id='zero'")
        output = query.render(query.query(self.db, "sess_root", "tree"))
        self.assertRegex(output, r"Total\s+1\s+0\s+0\s+0\s+—\s+—\s+0.000000")
        output = query.render_summary(query.query(self.db, "sess_root", "tree"))
        self.assertIn("· 1 request · 0.00 credits", output)
        self.assertRegex(output, r"requested-model\s+1\s+0.00\s+0\s+0\s+—\s+—\n")
        self.assertNotIn("⚠", output)

    def test_model_hit_rate_is_a_token_share_with_coverage_and_total_pairs(self):
        self.captured("hit", conversation="root", tokens=100)
        self.captured("miss", conversation="root", tokens=900)
        self.captured("unknown", conversation="root", tokens=20)
        self.db.execute("UPDATE captures SET output_tokens=5,cache_read_tokens=50 WHERE id='hit'")
        self.db.execute("UPDATE captures SET output_tokens=5,cache_read_tokens=0 WHERE id='miss'")
        report = query.query(self.db, "sess_root", "tree")
        model = report["captures"]["models"][0]
        # A per-call average would give 25%; only the two calls with both counters enter the denominator.
        self.assertEqual(model["cache_hit_rate"],
                         {"cached": 50, "error": 0, "evaluable": 2, "input": 1000, "percentage": 5.0, "unknown": 1})
        self.assertEqual(model["metrics"]["total_tokens"], {"observed_sum": 1010, "known": 2, "unknown": 1})
        output = query.render(report)
        self.assertIn("~5.0% (2/3)", output)
        self.assertIn("1,010 (2/3)", output)
        self.assertIn("Other linked holds workflow steps and subagents and may include helpers/forks", output)
        self.assertRegex(query.render_summary(report), r"requested-model\s+3\s+3.00\s+1.0K\s+10\s+50\s+~5%\n")

    def test_summary_reports_missing_capture(self):
        with sqlite3.connect(":memory:") as empty:
            missing = query.query(empty, "sess_root", "tree")
        self.assertEqual(query.render_summary(missing), "Kiro usage · sess_root · tree · 0 requests · — credits\n⚠ capture unavailable")

    def test_summary_rounding_rounds_credits_and_tokens(self):
        self.assertEqual([query.credits_text(total) for total in (.004, .005, 2.834, 1234.5)],
                         ["<0.01", "0.01", "2.83", "1,234.50"])
        self.assertEqual([query.tokens_text(total) for total in (950, 999.6, 12_345, 99_960, 999_600, 1_234_567, 5e12)],
                         ["950", "1.0K", "12.3K", "100K", "1.0M", "1.2M", "5000B"])

    def test_summary_headline_sort_and_pool_line(self):
        root = "sess_90da0f80-0000-4000-8000-000000000000"
        for ident, model, credits in (("a", "cheap", .01), ("b", "costly", 2), ("c", "unpriced", None), ("d", "also-cheap", .01)):
            self.captured(ident, conversation=root, credits=credits, metadata={"model": model})
        self.captured("e", conversation="child", credits=.5, metadata={"model": "costly", "kiro:root_conversation_id": root})
        output = query.render_summary(query.query(self.db, root, "tree"))
        lines = output.splitlines()
        self.assertEqual(lines[0], "Kiro usage · sess_90da0f80 · tree · 5 requests · 2.52 credits")
        self.assertEqual([line.split()[0] for line in lines[3:7]], ["costly", "also-cheap", "cheap", "unpriced"])
        self.assertEqual([line.split()[:3] for line in lines[8:13]],
                         [["Conversation", "Requests", "Credits"], ["Main", "4", "2.02"], ["Sub/WF", "1", "0.50"], ["-" * 59], ["Total", "5", "2.52"]])
        self.assertEqual(lines[13], "⚠ credits unknown for 1/5 requests; tokens missing for 5")
        self.db.execute("UPDATE captures SET credits=1 WHERE id='c'")
        self.assertTrue(query.render_summary(query.query(self.db, root, "tree"), ["x", "y"]).endswith("\n⚠ tokens missing for 5; x; y"))

    def test_run_report_counts_only_the_invocations_calls_per_root(self):
        run, earlier = {"invocation": "a" * 32}, {"invocation": "b" * 32}
        self.session("sess_root")  # its disk credits and request ID would join the tree report, never a run
        self.captured("main", conversation="sess_root", credits=1, metadata=run)
        self.captured("helper", conversation="sess_helper", credits=2, metadata={**run, "kiro:root_conversation_id": "root"})
        self.captured("unpriced", conversation="sess_root", credits=None, metadata=run)
        self.captured("fork", conversation="sess_fork", credits=4, metadata=run)
        self.captured("before", conversation="sess_root", credits=8, metadata=earlier)
        self.captured("unmarked", conversation="sess_root", credits=16)
        self.captured("disk-mapped", request="request-sess_root", credits=32, metadata=run)
        self.assertEqual(query.query(self.db, "sess_root", "tree")["captures"]["observations"], 6)
        report = query.run_report(self.db, "a" * 32, "sess_root")
        pools = report["captures"]["pools"]
        self.assertEqual([pools[pool]["observations"] for pool in ("root_conversation", "other_linked_conversations", "unknown")], [2, 1, 0])
        lines = query.render_summary(report).splitlines()
        self.assertEqual(lines[0], "Kiro usage · sess_root · this run · 3 requests · 3.00 credits")
        self.assertEqual(lines[-1], "⚠ credits unknown for 1/3 requests; tokens missing for 3")
        self.assertEqual(query.render_summary(query.run_report(self.db, "a" * 32, "sess_fork")).splitlines()[0],
                         "Kiro usage · sess_fork · this run · 1 request · 4.00 credits")

    def test_summary_tables_share_column_widths_and_total_row_closes_the_second(self):
        for ident, conversation, tokens in (("a", "root", 5), ("b", "child", 123_456_789)):
            self.captured(ident, conversation=conversation, tokens=tokens, metadata={"kiro:root_conversation_id": "root"})
        lines = query.render_summary(query.query(self.db, "sess_root", "tree")).splitlines()
        header, models, _, groups, main, sub, _, total = lines[2:10]
        self.assertEqual(total.split()[1:4], ["2", "2.00", "123M"])
        self.assertEqual({len(line) for line in (header, models, groups, main, sub, total)}, {len(header)})

    def estimable(self, ident, credits, chars=0, model=OPUS, conversation="root", context=3.0):
        self.captured(ident, conversation=conversation, credits=credits, tokens=None, metadata={"model": model})
        self.db.execute("UPDATE captures SET context_usage_percentage=?,summary_json=? WHERE id=?",
                        (context, json.dumps({"output_text_chars": chars}), ident))

    def test_estimates_fill_only_missing_counters_and_mark_coverage(self):
        self.estimable("miss", .4)
        self.estimable("hit", .1, conversation="child")
        self.db.execute("""UPDATE captures SET metadata_json=json_set(metadata_json,'$."kiro:root_conversation_id"','root') WHERE id='hit'""")
        self.estimable("other", .1, model="other-model")  # no window: stays unknown
        self.estimable("exact", .1)  # exact counters win over its estimate
        self.db.execute("UPDATE captures SET input_tokens=100,output_tokens=5,cache_read_tokens=0 WHERE id='exact'")
        with patch.dict(query.credit_discount.RATES, {OPUS: RATES}):
            report = query.query(self.db, "sess_root", "tree")
        estimates = report["captures"]["estimates"]
        self.assertEqual(estimates, {
            "cache_hit_rate": {"cached": 30000, "error": None, "evaluable": 3, "input": 60100,
                               "percentage": 49.91680532445923, "unknown": 1},
            "cache_read_tokens": {"observed_sum": 30000, "known": 3, "unknown": 1},
            "input_tokens": {"observed_sum": 60100, "known": 3, "unknown": 1},
            "output_tokens": {"observed_sum": 5, "known": 3, "unknown": 1},
            "total_tokens": {"observed_sum": 60105, "known": 3, "unknown": 1},
        })
        models = {model["requested_model"]: model for model in report["captures"]["models"]}
        self.assertEqual(set(models), {OPUS, "other-model"})
        self.assertEqual(models["other-model"]["estimates"], {})
        self.assertEqual(report["captures"]["metrics"]["input_tokens"], {"observed_sum": 100, "known": 1, "unknown": 3})
        self.assertRegex(query.render_summary(report), r"claude-opus-5.5\s+3\s+0\.60\s+~60.1K\s+~5\s+~30.0K\s+~50%\n")
        self.assertRegex(query.render_summary(report), r"\nTotal\s+4\s+0\.70\s+~60.1K\s+~5\s+~30.0K\s+~50%\n⚠ tokens missing for 1$")
        output = query.render(report)
        self.assertRegex(output, r"Total\s+4\s+~60,105 \(3/4\)\s+~60,100 \(3/4\)\s+~5 \(3/4\)\s+~30,000 \(3/4\)\s+~49.9% \(3/4\)")
        self.assertRegex(output, r"Other linked\s+1\s+~30,000\s+~30,000\s+~0\s+~30,000\s+~100.0%")
        self.assertRegex(output, r"other-model\s+1\s+—\s+—\s+—\s+—\s+—")

    def test_estimated_fit_noise_is_a_negligible_share(self):
        # .400697 credits buys 29 cached tokens on a 29,999-token input under the synthetic schedule.
        self.estimable("noise", .400697, chars=4)
        with patch.dict(query.credit_discount.RATES, {OPUS: RATES}):
            rate = query.query(self.db, "sess_root")["captures"]["estimates"]["cache_hit_rate"]
        self.assertEqual((rate["cached"], rate["input"], rate["evaluable"]), (29, 29_999, 1))

    def test_cached_and_hit_cells_show_the_cached_standard_error(self):
        """Two full hits at a 10% credit error: standard errors add in quadrature, as a share of cached tokens.
        A call whose model has rates but no credit_error leaves its group's error unknown."""
        unrated_error = "claude-sonnet-5.5"
        with patch.dict(query.credit_discount.RATES, {OPUS: {**RATES, "credit_error": .1}, unrated_error: RATES}):
            self.estimable("one", .1)
            self.estimable("two", .1)
            report = query.query(self.db, "sess_root")
            self.estimable("unknown-error", .1, model=unrated_error)
            mixed = query.query(self.db, "sess_root")
        rate = report["captures"]["estimates"]["cache_hit_rate"]
        # Each call contributes 1,000 tokens of error. Independent errors combine to ~1,414, not 2,000.
        self.assertAlmostEqual(rate["error"], 1414.213562373095)
        self.assertRegex(query.render(report), r"Total\s+2\s+~60,000\s+~60,000\s+~0\s+~60,000 ±2%\s+~100.0% ±2%\s")
        self.assertIsNone(mixed["captures"]["estimates"]["cache_hit_rate"]["error"])
        self.assertEqual(query.value("±é\x1b\\"), "±\\xe9\\x1b\\\\")  # only ± passes unescaped
        self.assertEqual([query.error_text(error, 1000) for error in (9.9, 10)], ["", " ±1%"])

    def test_summary_tables_omit_coverage_and_note_missing_tokens(self):
        """Session, run and store summaries move missing token coverage to the caveat."""
        self.estimable("rated", .01, chars=40)
        self.captured("unknown", conversation="root", credits=.01, tokens=None, metadata={"model": "unknown-model"})
        cell = r"~\S+"
        row = rf"\s+2\s+0.02\s+{cell}\s+{cell}\s+{cell}\s+~\d+%"
        summary = query.render_summary(query.query(self.db, "sess_root"))
        store = report.render(report.store_report(self.db))
        self.assertRegex(summary, rf"\nMain{row}\n")
        self.assertRegex(store, rf"\nTotal{row}(\n|$)")
        self.assertRegex(store, rf"\nunknown-model\s+1\s+0.01\s+—\s+—\s+—\s+—")
        for text in (summary, store):
            self.assertNotRegex(text, r"\(\d+/\d+\)")
            self.assertTrue(text.endswith("⚠ tokens missing for 1"))

    def test_report_survives_a_capture_committed_between_its_queries(self):
        """Totals, groups and per-call estimates read one snapshot: a capture committed after the groups and before
        the per-call query is in none of them, rather than in a call with no group."""
        path = Path(tempfile.mkdtemp()) / "race.sqlite3"
        self.addCleanup(lambda: [path.with_name(path.name + s).unlink(missing_ok=True) for s in ("", "-wal", "-shm")])
        writer = sqlite3.connect(path)
        self.addCleanup(writer.close)
        writer.executescript(capture.SCHEMA)
        writer.execute("PRAGMA journal_mode=WAL")
        arrivals = []

        def add(ident, stamp):
            writer.execute("""INSERT INTO captures(id,started_utc_ns,metadata_json,response_json,credits,
                           context_usage_percentage,summary_json,state,completion_seen,issues_json) VALUES (?,?,?,?,?,?,?,?,?,?)""",
                           (ident, stamp, json.dumps({"model": "claude-opus-5.5"}), "{}", .1, 3.0,
                            '{"output_text_chars":40}', "complete", 1, "[]"))
            writer.commit()

        add("first", 1793404800000000000)

        class Reader(sqlite3.Connection):
            def execute(self, sql, parameters=()):
                if "SELECT c.id,c.metadata_json,c.credits" in sql and not arrivals:
                    arrivals.append(add("arriving", 1793491200000000000))
                return super().execute(sql, parameters)

        reader = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, factory=Reader)
        self.addCleanup(reader.close)
        result = report.store_report(reader)
        self.assertEqual(len(arrivals), 1)
        self.assertEqual(result["captures"]["observations"], 1)
        self.assertEqual([day["observations"] for day in result["captures"]["days"]], [1])
        self.assertEqual(report.store_report(reader)["captures"]["observations"], 2)  # the next report sees it

    def test_cached_error_is_a_share_of_its_own_total(self):
        """An exact 30,000 cached tokens on a call with no input joins Cached's 60,000 but not Cache hit's pairs, so
        the estimated hit's one error is half the share of Cached it is of Cache hit."""
        with patch.dict(query.credit_discount.RATES, {OPUS: {**RATES, "credit_error": .1}}):
            self.estimable("estimated", .1)
            self.captured("exact", conversation="root", tokens=None, metadata={"model": OPUS})
            self.db.execute("UPDATE captures SET cache_read_tokens=30000 WHERE id='exact'")
            report = query.query(self.db, "sess_root")
        self.assertAlmostEqual(report["captures"]["estimates"]["cache_hit_rate"]["error"], 1_000)
        self.assertRegex(query.render(report), r"Total\s+2\s+.*~60,000 ±2%\s+~100.0% ±3% \(1/2\)\s")
        summary = query.render_summary(report)
        for label in (OPUS, "Main", "Total"):
            with self.subTest(label=label):
                self.assertRegex(summary, rf"\n{re.escape(label)}\s+2\s+.*~60.0K ±2%\s+~100% ±3%(\n|$)")

    def test_exact_cached_over_estimated_input_is_an_estimated_share(self):
        self.estimable("partial", .1)
        self.db.execute("UPDATE captures SET cache_read_tokens=15000 WHERE id='partial'")
        rate = query.query(self.db, "sess_root")["captures"]["estimates"]["cache_hit_rate"]
        self.assertEqual(rate, {"cached": 15000, "error": 0, "evaluable": 1, "input": 30000,
                                "percentage": 50.0, "unknown": 0})

    def test_estimates_respect_the_calls_exact_counters(self):
        with patch.dict(query.credit_discount.RATES, {OPUS: RATES}):
            estimate = query.credit_discount.estimate
            # A charge below the fixed fee must still not estimate more cached tokens than the exact input.
            self.assertEqual(estimate(OPUS, 3.0, .001, 4, input=1200)["cache_read_tokens"], 1200)
            guess = estimate(OPUS, 3.0, .0146, 4, output=2000)
        self.assertEqual((guess["output_tokens"], guess["input_tokens"]), (2000, 28000))

    def test_zero_input_estimate_is_not_a_cache_hit(self):
        self.estimable("empty", .001, context=0.0)
        rate = query.query(self.db, "sess_root")["captures"]["estimates"]["cache_hit_rate"]
        self.assertIsNone(rate["percentage"])

    def test_tool_and_reasoning_characters_count_as_estimated_output(self):
        self.estimable("tools", .4)
        events = [("response.function_call_arguments.delta", {"type": "response.function_call_arguments.delta", "delta": "x" * 40}),
                  ("response.reasoning_text.delta", {"type": "response.reasoning_text.delta", "delta": "y" * 20}),
                  ("toolUseEvent", {"input": "z" * 16, "name": "shell"}),
                  ("reasoningContentEvent", {"text": "w" * 4}),
                  ("response.function_call_arguments.done", {"type": "response.function_call_arguments.done", "arguments": "x" * 40})]
        self.db.executemany("INSERT INTO events(capture_id,seq,event_name,data_json) VALUES ('tools',?,?,?)",
                            [(seq, name, json.dumps(data)) for seq, (name, data) in enumerate(events)])
        self.assert_estimated_output(20)  # 80 chars; .done repeats arguments already counted in a delta

    def test_live_tool_and_reasoning_counts_win_over_retained_events(self):
        # The collector counted 60 chars live although the queue omitted most event copies; one stray copy survived.
        self.estimable("live", .4)
        self.db.execute("UPDATE captures SET summary_json=? WHERE id='live'", (json.dumps({"output_text_chars": 0, "tool_chars": 40, "reasoning_chars": 20}),))
        self.db.execute("INSERT INTO events(capture_id,seq,event_name,data_json) VALUES ('live',0,'toolUseEvent',?)", (json.dumps({"input": "z" * 400}),))
        self.assert_estimated_output(15)

    def completed(self, ident, output, deltas=()):
        events = [*deltas, ("response.completed", {"type": "response.completed", "response": {"output": output}})]
        self.db.executemany("INSERT INTO events(capture_id,seq,event_name,data_json) VALUES (?,?,?,?)",
                            [(ident, seq, name, json.dumps(data)) for seq, (name, data) in enumerate(events)])

    def test_terminal_only_tool_and_reasoning_output_counts_once(self):
        self.estimable("terminal", .4)
        self.completed("terminal", [{"type": "function_call", "name": "shell", "arguments": "x" * 400}])
        self.assert_estimated_output(100)
        # A repeated completed event is the same output, not twice as much.
        self.db.execute("INSERT INTO events(capture_id,seq,event_name,data_json) SELECT capture_id,seq+100,event_name,data_json FROM events WHERE capture_id='terminal'")
        self.assert_estimated_output(100)
        # Deltas present: their terminal copies are not recounted; terminal-only reasoning still counts.
        self.db.execute("DELETE FROM captures")
        self.db.execute("DELETE FROM events")
        self.estimable("mixed", .4)
        self.completed("mixed", [{"type": "function_call", "arguments": "x" * 40},
                                 {"type": "reasoning", "content": [{"type": "reasoning_text", "text": "y" * 20}]}],
                       [("response.function_call_arguments.delta", {"type": "response.function_call_arguments.delta", "delta": "x" * 40})])
        self.assert_estimated_output(15)

    def assert_estimated_output(self, tokens):
        with patch.dict(query.credit_discount.RATES, {OPUS: RATES}):
            metrics = query.query(self.db, "sess_root")["captures"]["estimates"]
        self.assertEqual(metrics["output_tokens"], {"observed_sum": tokens, "known": 1, "unknown": 0})
        self.assertEqual(metrics["input_tokens"], {"observed_sum": 30_000 - tokens, "known": 1, "unknown": 0})

    def test_estimator_refuses_unknown_inputs(self):
        with patch.dict(query.credit_discount.RATES, {OPUS: RATES}):
            estimate = query.credit_discount.estimate
            self.assertIsNone(estimate(OPUS, None, 1, 0))
            self.assertEqual(estimate(OPUS, 3.0, None, 8),
                             {"total_tokens": 30000, "input_tokens": 29998, "output_tokens": 2,
                              "cache_read_tokens": None, "cache_read_error": None})
            # Interrupted capture: exact input, no output count or characters; no cache split.
            self.assertEqual(estimate(OPUS, 3.0, 1, None, input=1200),
                             {"total_tokens": 30000, "input_tokens": 1200, "output_tokens": None,
                              "cache_read_tokens": None, "cache_read_error": None})
            self.assertEqual(estimate(OPUS, 3.0, 100, 0)["cache_read_tokens"], 0)  # clamped, not negative
            self.assertEqual(estimate(OPUS, .001, 1, 1000)["input_tokens"], 0)  # output capped at total

    def test_human_output_separates_sources_and_exposes_missing_coverage(self):
        self.session("sess_root", credits=8)
        self.captured("zero", conversation="root", credits=0, tokens=0)
        self.captured("missing", conversation="root", credits=None, tokens=None, state="incomplete")
        report = query.query(self.db, "sess_root")
        output = query.render(report)
        self.assertIn("Session: sess_root  Scope: session (1 session)", output)
        self.assertRegex(output, r"Total\s+2\s+—\s+0 \(1/2\)\s+—\s+—\s+—\s+0.000000 \(1/2\)")
        self.assertIn("Partial cells: sum (known/all requests); ~ adds estimates where a call lacks the exact counter; — unavailable.", output)
        self.assertIn("Own-versus-delegate attribution within a session is unavailable", output)
        self.assertIn("credits 1/2; input 1/2; output 0/2", output)
        self.assertIn("2 attributed calls; 1 incomplete", output)
        self.assertIn("Turns: 1; observed credits: 8", output)
        self.assertIn("not a per-call model", output)
        self.assertNotIn("observed credits: 8.0", output)

    def test_human_counts_use_grouping(self):
        self.captured("large", conversation="root", credits=1234.5, tokens=1234567)
        output = query.render(query.query(self.db, "sess_root"))
        self.assertRegex(output, r"requested-model\s+1\s+—\s+1,234,567\s+—\s+—\s+—\s+1,234.500000")

    def test_human_empty_sources_and_unknown_model(self):
        with sqlite3.connect(":memory:") as empty:
            output = query.render(query.query(empty, "sess_unknown"))
        self.assertRegex(output, r"Total\s+—\s+—\s+—\s+—\s+—\s+—\s+—")
        self.assertIn("Capture coverage unavailable", output)
        self.assertIn("Disk coverage unavailable", output)
        self.captured("unknown", conversation="root")
        self.db.execute("UPDATE captures SET metadata_json=?", (json.dumps({"kiro:conversation_id": "root"}),))
        self.assertRegex(query.render(query.query(self.db, "sess_root")), r"\n—\s+1\s+—\s+10\s+—\s+—\s+—\s+1\.000000")
        self.db.execute("UPDATE captures SET metadata_json=?", (json.dumps({"kiro:conversation_id": "root", "model": "bad\n\x1b[31m"}),))
        output = query.render(query.query(self.db, "sess_root"))
        self.assertIn(r"bad\n\x1b[31m", output)

    def test_multiple_metering_events_warn_without_changing_totals(self):
        for ident, conversation, events in (("twice", "root", 2), ("once", "root", 1), ("elsewhere", "other", 3)):
            self.captured(ident, conversation=conversation)
            self.db.execute("UPDATE captures SET summary_json=? WHERE id=?", (json.dumps({"metering_events": events}), ident))
        report = query.query(self.db, "sess_root")
        self.assertEqual((report["captures"]["multiple_metering_events"], report["captures"]["incomplete"]), (1, 0))
        self.assertEqual(report["captures"]["metrics"]["credits"]["observed_sum"], 2)
        self.assertIn("1 selected call(s) carried more than one meteringEvent", " ".join(report["warnings"]))
        self.assertRegex(query.render_summary(report), r"\n⚠ (.*; )?1 multi-metered call$")
        report["captures"]["multiple_metering_events"] = 2
        self.assertRegex(query.render_summary(report), r"\n⚠ (.*; )?2 multi-metered calls$")
        self.db.execute("UPDATE captures SET summary_json=NULL WHERE id='twice'")
        self.assertFalse(any("meteringEvent" in warning for warning in query.query(self.db, "sess_root")["warnings"]))

    def test_cli_json_preserves_report_and_human_diagnostics_use_stderr(self):
        self.session("sess_root")
        self.captured("call", conversation="root")
        expected = query.query(self.db, "sess_root")
        with tempfile.TemporaryDirectory() as temporary:
            command = [sys.executable, query.__file__, "--db", str(self.report_db(temporary)), "--session", "sess_root"]
            structured = subprocess.run([*command, "--json"], capture_output=True, text=True)
            self.assertEqual(structured.returncode, 0, structured.stderr)
            self.assertEqual(json.loads(structured.stdout), expected)
            self.assertEqual(structured.stderr, "")
            human = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(human.returncode, 0, human.stderr)
            self.assertIn("Captured calls", human.stdout)
            self.assertNotIn("Warning:", human.stdout)
            self.assertNotIn("must never be added", human.stderr)
            self.assertIn("must never be added", human.stdout)
            self.assertIn("Context percentages", human.stderr)
            self.assertIn("1 attributed call;", human.stdout)
            self.assertIn("last index and may be stale", human.stdout)

    def test_cli_missing_database_is_not_created(self):
        with tempfile.TemporaryDirectory() as temporary:
            missing = Path(temporary) / "absent.sqlite"
            result = subprocess.run([sys.executable, query.__file__, "--db", str(missing),
                                     "--session", "sess_root"], capture_output=True, text=True)
            self.assertEqual((result.returncode, result.stdout, result.stderr),
                             (1, "", "cannot query calibration database: unable to open database file\n"))
            self.assertFalse(missing.exists())

    def local_days(self):
        """Pin a POSIX zone, so local days differ from UTC ones without zoneinfo; report.py children inherit it."""
        patcher = patch.dict(os.environ, {"TZ": "MST7"})
        patcher.start()
        self.addCleanup(time.tzset)
        self.addCleanup(patcher.stop)
        time.tzset()

    def started(self, ident, utc):
        nanoseconds = int(datetime.fromisoformat(utc).timestamp()) * 10**9
        self.db.execute("UPDATE captures SET started_utc_ns=? WHERE id=?", (nanoseconds, ident))

    def report_db(self, temporary):
        self.db.commit()
        path = Path(temporary) / "synthetic.sqlite"
        with closing(sqlite3.connect(path)) as target:
            self.db.backup(target)
        return path

    def test_report_models_and_conversations_keep_local_day_bounds_and_session_estimates(self):
        self.local_days()
        self.estimable("rated", .01, chars=40)
        self.estimable("unrated", .02, chars=40, model="claude-opus-4.5", conversation=None)  # window, no rates entry; unattributed
        self.estimable("windowless", None, chars=40, model="requested-model")  # neither; credits unknown
        for ident, utc in (("rated", "2026-10-29T18:00:00+00:00"), ("unrated", "2026-10-30T03:00:00+00:00"),
                           ("windowless", "2026-10-30T18:00:00+00:00")):
            self.started(ident, utc)
        store = report.store_report(self.db)
        captures = store["captures"]
        # 03:00 UTC on the 30th is the 29th at UTC-7.
        self.assertEqual([(day["day"], day["observations"]) for day in captures["days"]], [("2026-10-29", 2), ("2026-10-30", 1)])
        models = {model["requested_model"]: model for model in captures["models"]}
        self.assertEqual(models["claude-opus-4.5"]["estimates"]["input_tokens"]["known"], 1)
        self.assertNotIn("cache_read_tokens", models["claude-opus-4.5"]["estimates"])  # no rates entry, so no cache split
        self.assertEqual(models["requested-model"]["estimates"], {})  # no window, so no ~tokens
        tree = {model["requested_model"]: model for model in query.query(self.db, "sess_root", "tree")["captures"]["models"]}
        self.assertEqual(models["claude-opus-5.5"]["estimates"], tree["claude-opus-5.5"]["estimates"])  # one per-call estimate path
        text = report.render(store)
        self.assertTrue(text.startswith("Kiro usage · all captures · 3 requests · 0.03 credits\n\nModel "), text)
        self.assertNotIn("\nDay ", text)
        self.assertRegex(text, r"\nConversation\s+Requests.*\nMain\s+0.*\nSub/WF\s+2.*\nUnknown\s+1")
        self.assertEqual({pool: source["observations"] for pool, source in captures["pools"].items()},
                         {"other_linked_conversations": 2, "root_conversation": 0, "unknown": 1})
        self.assertRegex(text, r"\nModel\s+Requests\s+Credits\s+In\s+Out\s+Cached\s+Cache hit\nclaude-opus-4.5\s+1\s+0.02\s+~")
        self.assertTrue(text.endswith("\n⚠ credits unknown for 1/3 requests; tokens missing for 1"))
        self.assertEqual([day["day"] for day in report.store_report(self.db, since="2026-10-30")["captures"]["days"]], ["2026-10-30"])
        bounded = report.store_report(self.db, "2026-10-29", "2026-10-29")
        self.assertEqual((bounded["captures"]["observations"], [model["requested_model"] for model in bounded["captures"]["models"]]),
                         (2, ["claude-opus-4.5", "claude-opus-5.5"]))
        self.assertTrue(report.render(bounded).startswith("Kiro usage · all captures · 2026-10-29 – 2026-10-29 · 2 requests"))
        with tempfile.TemporaryDirectory() as temporary:
            path, theme = self.report_db(temporary), Path(temporary) / "theme.json"
            theme.write_text(json.dumps({"border": "ascii"}))
            command = [sys.executable, report.__file__, "--db", str(path)]
            for arguments, rendered in (([], report.render(store)), (["--summary-theme", str(theme)], report.render(store, query.summary_theme.load(theme, io.StringIO())))):
                result = subprocess.run([*command, *arguments], capture_output=True, text=True)
                self.assertEqual((result.returncode, result.stderr), (0, ""))
                self.assertEqual(result.stdout, rendered + "\n" + query.calculator_text([store]) + "\n")
            structured = subprocess.run([*command, "--json", "--until", "2026-10-29"], capture_output=True, text=True)
            structured_captures = json.loads(structured.stdout)["captures"]
            self.assertEqual(structured_captures["observations"], 2)
            self.assertEqual(structured_captures["pools"], bounded["captures"]["pools"])
            for flag, invalid in (("--since", "20261030"), ("--until", "2026-10")):
                with self.subTest(flag=flag, invalid=invalid):
                    result = subprocess.run([*command, flag, invalid], capture_output=True, text=True)
                    self.assertEqual((result.returncode, result.stdout), (2, ""))
                    self.assertIn(f"argument {flag}: invalid day value: {invalid!r}", result.stderr)
            self.assertIn("MST", subprocess.run([*command, "--help"], capture_output=True, text=True).stdout)
            empty = Path(temporary) / "empty.sqlite"
            sqlite3.connect(empty).close()
            result = subprocess.run([sys.executable, report.__file__, "--db", str(empty)], capture_output=True, text=True)
            self.assertEqual((result.returncode, result.stderr), (1, "cannot query calibration database: no capture source has initialized this database\n"))

    def test_store_pools_use_recorded_root_identity_for_responses_and_rpc(self):
        # Unique credit weights identify each member; equal pool counts could hide swapped calls.
        for ident, conversation, root, path, credits in (
                ("child", "child", "root", "/v1/responses", 1),
                ("empty", "", "root", "/v1/responses", 2),
                ("main", "root", "root", "/v1/responses", 4),
                ("missing", None, "root", "/v1/responses", 8),
                ("no-root", "root", None, "/v1/responses", 16),
                ("rpc", "root", "root", "/rpc", 32)):
            self.captured(ident, conversation=conversation, credits=credits,
                          metadata={"kiro:root_conversation_id": root, "path": path})
        captures = report.store_report(self.db)["captures"]
        self.assertEqual({pool: (source["observations"], source["metrics"]["credits"]["observed_sum"])
                          for pool, source in captures["pools"].items()},
                         {"other_linked_conversations": (2, 17), "root_conversation": (2, 36), "unknown": (2, 10)})
        self.assertEqual(captures["metrics"]["credits"]["observed_sum"], 63)
        self.db.execute("DELETE FROM captures")
        empty = report.store_report(self.db)
        self.assertEqual([source["observations"] for source in empty["captures"]["pools"].values()], [0, 0, 0])
        self.assertRegex(report.render(empty), r"\nMain\s+0.*\nSub/WF\s+0")

    def test_summary_counts_requests_missing_either_token_counter_once(self):
        for ident in ("input-only", "neither", "output-only"):
            self.captured(ident, conversation="root", tokens=None if ident != "input-only" else 10)
        self.db.execute("UPDATE captures SET output_tokens=5 WHERE id='output-only'")
        self.assertTrue(report.render(report.store_report(self.db)).endswith("⚠ tokens missing for 3"))
        self.estimable("context-only", .01)
        self.db.execute("UPDATE captures SET summary_json=NULL WHERE id='context-only'")
        self.assertTrue(report.render(report.store_report(self.db)).endswith("⚠ tokens missing for 4"))
        self.db.execute("UPDATE captures SET input_tokens=0,output_tokens=0")
        self.assertNotIn("tokens missing", report.render(report.store_report(self.db)))

    def test_report_sessions_replay_each_tree_exit_summary_in_the_window(self):
        self.local_days()
        self.estimable("rated", .01, chars=40)
        self.estimable("unrated", .02, chars=40, model="claude-opus-4.5", conversation="child")
        self.db.execute("""UPDATE captures SET metadata_json=json_set(metadata_json,'$."kiro:root_conversation_id"','root') WHERE id='unrated'""")
        self.estimable("fork", .03, chars=40, model="requested-model", conversation="fork")  # a second root, e.g. after /chat fork
        for ident, utc in (("rated", "2026-10-29T18:00:00+00:00"), ("unrated", "2026-10-30T18:00:00+00:00"), ("fork", "2026-10-30T19:00:00+00:00")):
            self.started(ident, utc)
        reports = [query.query(self.db, session, "tree") for session in ("sess_root", "sess_fork")]
        windowed = query.query(self.db, "sess_root", "tree", since="2026-10-30")
        self.assertEqual([model["requested_model"] for model in windowed["captures"]["models"]], ["claude-opus-4.5"])
        self.assertEqual(query.query(self.db, "sess_root", "tree", until="2026-10-29")["captures"]["observations"], 1)
        with tempfile.TemporaryDirectory() as temporary:
            command = [sys.executable, report.__file__, "--db", str(self.report_db(temporary)), "--session", "sess_root"]
            result = subprocess.run([*command, "--session", "sess_fork"], capture_output=True, text=True)
            self.assertEqual((result.returncode, result.stderr), (0, ""))
            self.assertEqual(result.stdout, "\n\n".join(map(query.render_summary, reports)) + "\n" + query.calculator_text(reports) + "\n")
            self.assertIn("Kiro usage · sess_root · tree · 2 requests", result.stdout)
            self.assertIn("\n\nKiro usage · sess_fork · tree · 1 request", result.stdout)
            self.assertTrue(result.stdout.endswith("; no rates: claude-opus-4.5, requested-model; no context window: requested-model\n"))
            result = subprocess.run([*command, "--since", "2026-10-30"], capture_output=True, text=True)
            self.assertEqual(result.stdout, query.render_summary(windowed) + "\n" + query.calculator_text([windowed]) + "\n")
            structured = subprocess.run([*command, "--session", "sess_fork", "--json"], capture_output=True, text=True)
            self.assertEqual([item["session"] for item in json.loads(structured.stdout)], ["sess_root", "sess_fork"])
            result = subprocess.run([*command, "--session", "fork"], capture_output=True, text=True)
            self.assertEqual((result.returncode, result.stderr), (1, "cannot query calibration database: --session must be a sess_UUID identifier\n"))
        self.db.execute("DELETE FROM captures WHERE id!='rated'")
        self.assertEqual(query.calculator_text([query.query(self.db, "sess_root", "tree")]), "Calculator: rates.json fitted 2026-10-30")

    def test_report_keeps_the_last_nanosecond_before_midnight_on_its_day_and_escapes_model_names(self):
        self.local_days()
        self.estimable("late", .01, chars=40, model="bad\n\x1b[31m")
        midnight = int(datetime.fromisoformat("2026-10-31T00:00:00-07:00").timestamp()) * 10**9
        self.db.execute("UPDATE captures SET started_utc_ns=? WHERE id='late'", (midnight - 1,))
        store = report.store_report(self.db)
        self.assertEqual([day["day"] for day in store["captures"]["days"]], ["2026-10-30"])
        self.assertTrue(query.calculator_text([store]).endswith("no rates: bad\\n\\x1b[31m; no context window: bad\\n\\x1b[31m"))

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
        self.assertEqual(result["captures"]["global_unattributed_observations"], 1)
        self.assertTrue(any("global capture store" in warning for warning in result["warnings"]))
        self.db.execute("DROP TABLE disk_request_ids")
        result = query.query(self.db, "sess_root")
        self.assertEqual(result["captures"]["global_unattributed_observations"], 2)
        self.assertEqual(result["captures"]["observations"], 0)


if __name__ == "__main__":
    unittest.main()
