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
        self.assertEqual(tree["disk"]["turns"], 3)

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
        self.assertEqual(tree["attribution"]["own_vs_delegate"], "unavailable")
        self.captured("truly-unattributed", credits=99)
        mixed = query.query(self.db, "sess_root", "tree")
        self.assertEqual(mixed["captures"]["global_unattributed_observations"], 1)
        self.assertEqual(mixed["captures"]["observations"], 3)
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
        self.assertRegex(query.render_summary(report), r"Root conversation\s+2.*0.000000 \(1/2\)")
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
        self.assertNotIn("200.000000", query.render_summary(report))
        self.captured("request-only", request="request-sess_root", credits=4)
        self.captured("no-identity", credits=99)
        report = query.query(self.db, "sess_root", "tree")
        self.assertEqual(report["captures"]["observations"], 3)
        self.assertEqual(report["captures"]["pools"]["unknown"]["metrics"]["credits"]["observed_sum"], 4)
        self.assertEqual(sum(pool["observations"] for pool in report["captures"]["pools"].values()), 3)
        self.assertEqual(sum(pool["metrics"]["credits"]["observed_sum"] or 0 for pool in report["captures"]["pools"].values()), 7)

    def test_compact_summary_large_tree_partial_unknown_and_exact_zero(self):
        for index in range(1000):
            self.captured(str(index), conversation=f"child{index}", credits=.5,
                          metadata={"kiro:root_conversation_id": "root"})
        self.captured("missing", conversation="root", credits=None, tokens=None, state="incomplete")
        report = query.query(self.db, "sess_root", "tree")
        self.assertEqual(report["captures"]["observations"], 1001)
        self.assertEqual(report["captures"]["pools"]["other_linked_conversations"]["metrics"]["credits"],
                         {"observed_sum": 500, "known": 1000, "unknown": 0})
        output = query.render_summary(report)
        self.assertLess(len(output.splitlines()), 16)
        self.assertRegex(output, r"Total\s+1,001\s+—\s+10,000 \(1000/1001\)\s+—\s+—\s+—\s+500.000000 \(1000/1001\)")
        self.assertRegex(output, r"Root conversation\s+1\s+—\s+—\s+—\s+—\s+—\s+—")
        self.assertIn("credits known 1000/1001; incomplete 1", output)
        self.assertNotIn("child999", output)
        self.assertNotIn("~500", output)
        self.db.execute("DELETE FROM captures")
        self.captured("zero", conversation="root", credits=0, tokens=0)
        self.assertRegex(query.render_summary(query.query(self.db, "sess_root", "tree")),
                         r"Total\s+1\s+—\s+0\s+—\s+—\s+—\s+0.000000")

    def test_model_hit_rate_is_request_based_with_coverage_and_total_pairs(self):
        self.captured("hit", conversation="root", tokens=100)
        self.captured("miss", conversation="root", tokens=900)
        self.captured("unknown", conversation="root", tokens=20)
        self.db.execute("UPDATE captures SET output_tokens=5,cache_read_tokens=50 WHERE id='hit'")
        self.db.execute("UPDATE captures SET output_tokens=5,cache_read_tokens=0 WHERE id='miss'")
        report = query.query(self.db, "sess_root", "tree")
        model = report["captures"]["models"][0]
        self.assertEqual(model["cache_hit_rate"], {"hits": 1, "evaluable": 2, "unknown": 1, "percentage": 50})
        self.assertEqual(model["metrics"]["total_tokens"], {"observed_sum": 1010, "known": 2, "unknown": 1})
        output = query.render_summary(report)
        self.assertIn("~50.0% (2/3)", output)
        self.assertIn(query.capture_tables(report["captures"]), query.render(report))
        self.assertIn(query.capture_tables(report["captures"]), output)
        self.assertIn("1,010 (2/3)", output)
        self.assertNotIn("~5.0%", output)
        self.assertIn("Other linked holds workflow steps and subagents and may include helpers/forks", output)

    def test_compact_summary_only_labels_explicit_estimates(self):
        report = query.query(self.db, "sess_root", "tree")
        report["captures"]["estimates"] = {"input_tokens": query.metric(1234, 1, 1)}
        output = query.render_summary(report)
        self.assertRegex(output, r"Total\s+0\s+—\s+~1,234\s+—\s+—\s+—\s+—")
        with sqlite3.connect(":memory:") as empty:
            missing = query.render_summary(query.query(empty, "sess_root", "tree"))
        self.assertRegex(missing, r"Total\s+—\s+—\s+—\s+—\s+—\s+—\s+—")

    def estimable(self, ident, credits, chars=0, model="claude-opus-5.5", conversation="root", context=3.0):
        self.captured(ident, conversation=conversation, credits=credits, tokens=None, metadata={"model": model})
        self.db.execute("UPDATE captures SET context_usage_percentage=?,summary_json=? WHERE id=?",
                        (context, json.dumps({"output_text_chars": chars}), ident))

    def test_estimates_fill_only_missing_counters_and_mark_coverage(self):
        miss, hit = ((slope * 3.0 + .5034) / 603 for slope in (74, 20))  # full miss / full hit at 30,000 tokens
        self.estimable("miss", miss)
        self.estimable("hit", hit, conversation="child")
        self.db.execute("""UPDATE captures SET metadata_json=json_set(metadata_json,'$."kiro:root_conversation_id"','root') WHERE id='hit'""")
        self.estimable("other", hit, model="other-model")  # no window: stays unknown
        self.estimable("exact", hit)  # exact counters win over its estimate
        self.db.execute("UPDATE captures SET input_tokens=100,output_tokens=5,cache_read_tokens=0 WHERE id='exact'")
        report = query.query(self.db, "sess_root", "tree")
        estimates = report["captures"]["estimates"]
        self.assertEqual(estimates["total_tokens"], query.metric(60105, 3, 4))
        self.assertEqual(estimates["input_tokens"], query.metric(60100, 3, 4))
        self.assertEqual(estimates["output_tokens"], query.metric(5, 3, 4))
        self.assertEqual(estimates["cache_read_tokens"], query.metric(30000, 3, 4))
        self.assertEqual(estimates["cache_hit_rate"], {"hits": 1, "evaluable": 3, "unknown": 1, "percentage": 100 / 3})
        models = {model["requested_model"]: model for model in report["captures"]["models"]}
        self.assertEqual(models["other-model"]["estimates"], {})
        self.assertEqual(report["captures"]["metrics"]["input_tokens"], query.metric(100, 1, 4))
        output = query.render_summary(report)
        self.assertRegex(output, r"Total\s+4\s+~60,105 \(3/4\)\s+~60,100 \(3/4\)\s+~5 \(3/4\)\s+~30,000 \(3/4\)\s+~33.3% \(3/4\)")
        self.assertRegex(output, r"Other linked\s+1\s+~30,000\s+~30,000\s+~0\s+~30,000\s+~100.0%")
        self.assertRegex(output, r"other-model\s+1\s+—\s+—\s+—\s+—\s+—")

    def test_estimated_fit_noise_is_not_a_cache_hit(self):
        # Full-miss price with 5 chars: the fit leaves ~29 cached tokens, below 1% of input.
        self.estimable("noise", (74 * 3.0 + .5034) / 603, chars=5)
        report = query.query(self.db, "sess_root")
        self.assertGreater(report["captures"]["estimates"]["cache_read_tokens"]["observed_sum"], 0)
        self.assertEqual(report["captures"]["estimates"]["cache_hit_rate"]["hits"], 0)

    def test_estimates_respect_the_calls_exact_counters(self):
        estimate = query.credit_discount.estimate
        # Full-hit price on an exact 1,200-token input: cached is that input, never the ~29,999 guess.
        hit = 20 / 603 / 1e4 * 1200 + query.credit_discount.OUTPUT_RATE * 1 + .5034 / 603
        self.assertEqual(estimate("claude-opus-5.5", 3.0, hit, 4, input=1200)["cache_read_tokens"], 1200)
        self.assertEqual(estimate("claude-opus-5.5", 3.0, 1.0, 4, input=1200)["cache_read_tokens"], 0)
        guess = estimate("claude-opus-5.5", 3.0, hit, 4, output=2000)
        self.assertEqual((guess["output_tokens"], guess["input_tokens"]), (2000, 28000))

    def test_zero_input_estimate_is_not_a_cache_hit(self):
        self.estimable("empty", .001, context=0.0)
        rate = query.query(self.db, "sess_root")["captures"]["estimates"]["cache_hit_rate"]
        self.assertEqual(rate["hits"], 0)

    def test_tool_and_reasoning_characters_count_as_estimated_output(self):
        self.estimable("tools", (74 * 3.0 + .5034) / 603)
        events = [("response.function_call_arguments.delta", {"type": "response.function_call_arguments.delta", "delta": "x" * 40}),
                  ("response.reasoning_text.delta", {"type": "response.reasoning_text.delta", "delta": "y" * 20}),
                  ("toolUseEvent", {"input": "z" * 16, "name": "shell"}),
                  ("reasoningContentEvent", {"text": "w" * 4}),
                  ("response.function_call_arguments.done", {"type": "response.function_call_arguments.done", "arguments": "x" * 40})]
        self.db.executemany("INSERT INTO events(capture_id,seq,event_name,data_json) VALUES ('tools',?,?,?)",
                            [(seq, name, json.dumps(data)) for seq, (name, data) in enumerate(events)])
        metrics = query.query(self.db, "sess_root")["captures"]["estimates"]
        self.assertEqual(metrics["output_tokens"], query.metric(20, 1, 1))  # 80 chars / 4; .done is not recounted
        self.assertEqual(metrics["input_tokens"], query.metric(29980, 1, 1))

    def test_estimator_refuses_unknown_inputs(self):
        estimate = query.credit_discount.estimate
        self.assertIsNone(estimate("other-model", 3.0, 1, 0))
        self.assertIsNone(estimate("claude-opus-5.5", None, 1, 0))
        self.assertEqual(estimate("claude-opus-5.5", 3.0, None, 8),
                         {"total_tokens": 30000, "input_tokens": 29998, "output_tokens": 2, "cache_read_tokens": None})
        self.assertEqual(estimate("claude-opus-5.5", 3.0, 1, None)["output_tokens"], None)
        self.assertEqual(estimate("claude-opus-5.5", 3.0, 100, 0)["cache_read_tokens"], 0)  # clamped, not negative
        self.assertEqual(estimate("claude-opus-5.5", .001, 1, 1000)["input_tokens"], 0)  # output capped at total

    def test_human_output_separates_sources_and_exposes_missing_coverage(self):
        self.session("sess_root", credits=8)
        self.captured("zero", conversation="root", credits=0, tokens=0)
        self.captured("missing", conversation="root", credits=None, tokens=None, state="incomplete")
        report = query.query(self.db, "sess_root")
        output = query.render(report)
        self.assertIn("Session: sess_root  Scope: session (1 session)", output)
        self.assertIn("requested-model", output)
        self.assertRegex(output, r"Total\s+2\s+—\s+0 \(1/2\)\s+—\s+—\s+—\s+0.000000 \(1/2\)")
        self.assertRegex(output, r"requested-model\s+2\s+—\s+0 \(1/2\)\s+—\s+—\s+—\s+0.000000 \(1/2\)")
        self.assertIn("Partial cells: sum (known/all requests); ~ adds estimates where a call lacks the exact counter; — unavailable.", output)
        self.assertIn("must never be added", output)
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
        self.assertIn("—", query.render(query.query(self.db, "sess_root")))
        self.db.execute("UPDATE captures SET metadata_json=?", (json.dumps({"kiro:conversation_id": "root", "model": "bad\n\x1b[31m"}),))
        output = query.render(query.query(self.db, "sess_root"))
        self.assertIn(r"bad\n\x1b[31m", output)
        self.assertNotIn("\x1b", output)

    def test_multiple_metering_events_warn_without_changing_totals(self):
        for ident, conversation, events in (("twice", "root", 2), ("once", "root", 1), ("elsewhere", "other", 3)):
            self.captured(ident, conversation=conversation)
            self.db.execute("UPDATE captures SET summary_json=? WHERE id=?", (json.dumps({"metering_events": events}), ident))
        report = query.query(self.db, "sess_root")
        self.assertEqual((report["captures"]["multiple_metering_events"], report["captures"]["incomplete"]), (1, 0))
        self.assertEqual(report["captures"]["metrics"]["credits"]["observed_sum"], 2)
        self.assertIn("1 selected call(s) carried more than one meteringEvent", " ".join(report["warnings"]))
        self.db.execute("UPDATE captures SET summary_json=NULL WHERE id='twice'")
        self.assertFalse(any("meteringEvent" in warning for warning in query.query(self.db, "sess_root")["warnings"]))

    def test_cli_json_preserves_report_and_human_diagnostics_use_stderr(self):
        self.session("sess_root")
        self.captured("call", conversation="root")
        expected = query.query(self.db, "sess_root")
        self.db.commit()
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "synthetic.sqlite"
            with sqlite3.connect(path) as target:
                self.db.backup(target)
            command = [sys.executable, query.__file__, "--db", str(path), "--session", "sess_root"]
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
