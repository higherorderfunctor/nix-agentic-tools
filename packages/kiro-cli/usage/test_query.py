"""Synthetic calibration queries; no provider, home-directory or log reads."""

import json
import math
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import capture
import disk_index
import query

# Output tokens estimate() reads from opus chars, at rates.json's fitted chars_per_token.
opus_tokens = lambda chars: round(chars / query.credit_discount.RATES["claude-opus-5.5"]["chars_per_token"])


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
        self.assertRegex(query.render(report), r"Root conversation\s+2.*0.000000 \(1/2\)")
        summary = query.render_summary(report)
        self.assertEqual([line.split()[:3] for line in summary.splitlines()[6:12]],
                         [["Main", "2", "0.00"], ["Sub/WF", "1", "2.00"], ["Unknown", "1", "3.00"], ["-" * 62], ["Total", "4", "5.00"], ["⚠", "credits", "unknown"]])
        self.assertTrue(summary.endswith("\n⚠ credits unknown for 1/4 requests"))
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
        self.assertTrue(query.render_summary(report).endswith("\n⚠ 1 duplicate request ID"))
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
        output = query.render(report)
        self.assertRegex(output, r"Total\s+1,001\s+—\s+10,000 \(1000/1001\)\s+—\s+—\s+—\s+500.000000 \(1000/1001\)")
        self.assertRegex(output, r"Root conversation\s+1\s+—\s+—\s+—\s+—\s+—\s+—")
        output = query.render_summary(report)
        self.assertEqual(output, "\n".join([
            "Kiro usage · sess_root · tree · 1,001 requests · 500.00 credits", "",
            "Model            Requests  Credits     In  Out  Cached  Cache hit",
            "requested-model     1,001   500.00  10.0K    —       —          —", "",
            "Conversation     Requests  Credits     In  Out  Cached  Cache hit",
            "Main                    1        —      —    —       —          —",
            "Sub/WF              1,000   500.00  10.0K    —       —          —",
            "-" * 65,
            "Total               1,001   500.00  10.0K    —       —          —",
            "⚠ credits unknown for 1/1,001 requests; 1 incomplete"]))
        self.db.execute("DELETE FROM captures")
        self.captured("zero", conversation="root", credits=0, tokens=0)
        output = query.render(query.query(self.db, "sess_root", "tree"))
        self.assertRegex(output, r"Total\s+1\s+—\s+0\s+—\s+—\s+—\s+0.000000")
        output = query.render_summary(query.query(self.db, "sess_root", "tree"))
        self.assertIn("· 1 request · 0.00 credits", output)
        self.assertRegex(output, r"requested-model\s+1\s+0.00\s+0\s+—\s+—\s+—\n")
        self.assertNotIn("⚠", output)
        self.assertNotIn("Unknown", output)

    def test_model_hit_rate_is_a_token_share_with_coverage_and_total_pairs(self):
        self.captured("hit", conversation="root", tokens=100)
        self.captured("miss", conversation="root", tokens=900)
        self.captured("unknown", conversation="root", tokens=20)
        self.db.execute("UPDATE captures SET output_tokens=5,cache_read_tokens=50 WHERE id='hit'")
        self.db.execute("UPDATE captures SET output_tokens=5,cache_read_tokens=0 WHERE id='miss'")
        report = query.query(self.db, "sess_root", "tree")
        model = report["captures"]["models"][0]
        self.assertEqual(model["cache_hit_rate"], query.hit_share(50, 1000, 2, 3))  # 50 of 100 + 900 input tokens
        self.assertEqual(model["metrics"]["total_tokens"], {"observed_sum": 1010, "known": 2, "unknown": 1})
        output = query.render(report)
        self.assertIn("~5.0% (2/3)", output)
        self.assertIn(query.capture_tables(report["captures"]), output)
        self.assertIn("1,010 (2/3)", output)
        self.assertIn("Other linked holds workflow steps and subagents and may include helpers/forks", output)
        self.assertRegex(query.render_summary(report), r"requested-model\s+3\s+3.00\s+1.0K\s+10\s+50\s+~5%\n")

    def test_report_labels_only_explicit_estimates_and_missing_capture(self):
        report = query.query(self.db, "sess_root", "tree")
        report["captures"]["estimates"] = {"input_tokens": query.metric(1234, 1, 1)}
        output = query.render(report)
        self.assertRegex(output, r"Total\s+0\s+—\s+~1,234\s+—\s+—\s+—\s+—")
        with sqlite3.connect(":memory:") as empty:
            missing = query.query(empty, "sess_root", "tree")
        self.assertRegex(query.render(missing), r"Total\s+—\s+—\s+—\s+—\s+—\s+—\s+—")
        self.assertEqual(query.render_summary(missing), "Kiro usage · sess_root · tree · 0 requests · — credits\n⚠ capture unavailable")

    def test_summary_rounding_rounds_credits_and_tokens(self):
        self.assertEqual([query.credits_text(total) for total in (None, 0, .004, .005, 2.834, 1234.5)],
                         [None, "0.00", "<0.01", "0.01", "2.83", "1,234.50"])
        self.assertEqual([query.tokens_text(total) for total in (0, 950, 999.6, 12_345, 99_960, 318_000, 999_600, 1_234_567, 5e12)],
                         ["0", "950", "1.0K", "12.3K", "100K", "318K", "1.0M", "1.2M", "5000B"])

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
        self.assertEqual(lines[13], "⚠ credits unknown for 1/5 requests")
        self.db.execute("UPDATE captures SET credits=1 WHERE id='c'")
        self.assertNotIn("⚠", query.render_summary(query.query(self.db, root, "tree")))
        self.assertTrue(query.render_summary(query.query(self.db, root, "tree"), ["x", "y"]).endswith("\n⚠ x; y"))

    def test_summary_tables_share_column_widths_and_total_row_closes_the_second(self):
        for ident, conversation, tokens in (("a", "root", 5), ("b", "child", 123_456_789)):
            self.captured(ident, conversation=conversation, tokens=tokens, metadata={"kiro:root_conversation_id": "root"})
        lines = query.render_summary(query.query(self.db, "sess_root", "tree")).splitlines()
        header, models, blank, groups, main, sub, rule, total = lines[2:10]
        self.assertEqual((blank, rule), ("", "-" * len(groups)))
        self.assertEqual([line.split()[0] for line in (header, models, groups, main, sub, total)],
                         ["Model", "requested-model", "Conversation", "Main", "Sub/WF", "Total"])
        self.assertEqual(total.split()[1:4], ["2", "2.00", "123M"])
        self.assertEqual({len(line) for line in (header, models, groups, main, sub, total)}, {len(header)})
        self.assertNotIn("Unknown", "\n".join(lines))

    def estimable(self, ident, credits, chars=0, model="claude-opus-5.5", conversation="root", context=3.0):
        self.captured(ident, conversation=conversation, credits=credits, tokens=None, metadata={"model": model})
        self.db.execute("UPDATE captures SET context_usage_percentage=?,summary_json=? WHERE id=?",
                        (context, json.dumps({"output_text_chars": chars}), ident))

    def test_estimates_fill_only_missing_counters_and_mark_coverage(self):
        # Full miss / full hit at 30,000 tokens and no output, at rates.json's opus rates.
        rates = query.credit_discount.RATES["claude-opus-5.5"]
        miss, hit = (rates["fixed_per_call"] + rate * 30000 for rate in (rates["miss_input"], rates["hit_input"]))
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
        rates = query.credit_discount.RATES["claude-opus-5.5"]
        error = lambda credits: rates["credit_error"] * credits / (rates["miss_input"] - rates["hit_input"])
        expected = query.hit_share(30000, 60100, 3, 4, math.hypot(error(miss), error(hit)))
        self.assertEqual(estimates["cache_hit_rate"], expected)
        models = {model["requested_model"]: model for model in report["captures"]["models"]}
        self.assertEqual(models["other-model"]["estimates"], {})
        self.assertEqual(report["captures"]["metrics"]["input_tokens"], query.metric(100, 1, 4))
        self.assertRegex(query.render_summary(report), r"claude-opus-5.5\s+3\s+0.\d\d\s+~60.1K\s+~5\s+~30.0K\s+~50%\n")
        self.assertRegex(query.render_summary(report), r"\nTotal\s+4\s+0.67\s+~60.1K\s+~5\s+~30.0K\s+~50%$")
        output = query.render(report)
        self.assertRegex(output, r"Total\s+4\s+~60,105 \(3/4\)\s+~60,100 \(3/4\)\s+~5 \(3/4\)\s+~30,000 \(3/4\)\s+~49.9% \(3/4\)")
        self.assertRegex(output, r"Other linked\s+1\s+~30,000\s+~30,000\s+~0\s+~30,000\s+~100.0%")
        self.assertRegex(output, r"other-model\s+1\s+—\s+—\s+—\s+—\s+—")

    def test_estimated_fit_noise_is_a_negligible_share(self):
        # Full-miss price of 29,999 input tokens less 29 tokens' discount: below 1% of input.
        rates = query.credit_discount.RATES["claude-opus-5.5"]
        miss = rates["miss_input"] * 29999 + rates["output"] + rates["fixed_per_call"]
        self.estimable("noise", miss - 29 * (rates["miss_input"] - rates["hit_input"]), chars=5)
        report = query.query(self.db, "sess_root")
        self.assertGreater(report["captures"]["estimates"]["cache_read_tokens"]["observed_sum"], 0)
        self.assertLess(report["captures"]["estimates"]["cache_hit_rate"]["percentage"], .2)

    def test_cached_and_hit_cells_show_the_cached_standard_error(self):
        """Two full hits at a 10% credit error: standard errors add in quadrature, as a share of cached tokens.
        A call whose model has rates but no credit_error leaves its group's error unknown, so no ±."""
        rates = {**query.credit_discount.RATES["claude-opus-5.5"], "credit_error": .1}
        hit = query.credit_discount.price(rates, 30000, 0, 30000)
        sonnet = {key: value for key, value in query.credit_discount.RATES["claude-sonnet-5.5"].items() if key != "credit_error"}
        with patch.dict(query.credit_discount.RATES, {"claude-opus-5.5": rates, "claude-sonnet-5.5": sonnet}):
            self.estimable("one", hit)
            self.estimable("two", hit)
            report = query.query(self.db, "sess_root")
            self.estimable("unknown", hit, model="claude-sonnet-5.5")
            mixed = query.query(self.db, "sess_root")
        rate = report["captures"]["estimates"]["cache_hit_rate"]
        error = (2 * (.1 * hit / (rates["miss_input"] - rates["hit_input"])) ** 2) ** .5
        self.assertAlmostEqual(rate["error"], error)
        share = f"±{error / rate['cached']:.0%}"
        summary = query.render_summary(report)
        for label in ("claude-opus-5.5", "Main", "Total"):  # both summary tables
            self.assertRegex(summary, rf"\n{label}\s+2\s+\S+\s+~60.0K\s+~0\s+~60.0K {share}\s+~100% {share}(\n|$)")
        self.assertRegex(query.render(report), rf"Total\s+2\s+~60,000\s+~60,000\s+~0\s+~60,000 {share}\s+~100.0% {share}\s")
        self.assertIsNone(mixed["captures"]["estimates"]["cache_hit_rate"]["error"])
        self.assertEqual(query.value("±é\x1b\\"), "±\\xe9\\x1b\\\\")  # only ± passes unescaped
        self.assertNotIn("±", query.render(mixed).split("Pool")[1].splitlines()[1])  # Total row
        self.assertEqual([query.error_text(error, 1000) for error in (9.9, 10)], ["", " ±1%"])

    def test_cached_error_is_a_share_of_its_own_total(self):
        """An exact 30,000 cached tokens on a call with no input joins Cached's 60,000 but not Cache hit's pairs, so
        the estimated hit's one error is half the share of Cached it is of Cache hit."""
        rates = {**query.credit_discount.RATES["claude-opus-5.5"], "credit_error": .1}
        hit = query.credit_discount.price(rates, 30000, 0, 30000)
        with patch.dict(query.credit_discount.RATES, {"claude-opus-5.5": rates}):
            self.estimable("estimated", hit)
            self.captured("exact", conversation="root", tokens=None, metadata={"model": "claude-opus-5.5"})
            self.db.execute("UPDATE captures SET cache_read_tokens=30000 WHERE id='exact'")
            report = query.query(self.db, "sess_root")
        error = .1 * hit / (rates["miss_input"] - rates["hit_input"])
        self.assertAlmostEqual(report["captures"]["estimates"]["cache_hit_rate"]["error"], error)
        cached, paired = f"±{error / 60000:.0%}", f"±{error / 30000:.0%}"
        self.assertNotEqual(cached, paired)
        self.assertRegex(query.render(report), rf"Total\s+2\s+.*~60,000 {cached}\s+~100.0% {paired} \(1/2\)\s")
        summary = query.render_summary(report)
        for label in ("claude-opus-5.5", "Main", "Total"):
            self.assertRegex(summary, rf"\n{label}\s+2\s+.*~60.0K {cached}\s+~100% {paired}(\n|$)")

    def test_exact_cached_over_estimated_input_is_an_estimated_share(self):
        self.estimable("partial", .1)
        self.db.execute("UPDATE captures SET cache_read_tokens=15000 WHERE id='partial'")
        rate = query.query(self.db, "sess_root")["captures"]["estimates"]["cache_hit_rate"]
        self.assertEqual(rate, query.hit_share(15000, 30000, 1, 1))

    def test_estimates_respect_the_calls_exact_counters(self):
        estimate = query.credit_discount.estimate
        # Full-hit price on an exact 1,200-token input: cached is that input, never the ~29,999 guess.
        rates = query.credit_discount.RATES["claude-opus-5.5"]
        hit = rates["hit_input"] * 1200 + rates["output"] + rates["fixed_per_call"]
        self.assertEqual(estimate("claude-opus-5.5", 3.0, hit, 4, input=1200)["cache_read_tokens"], 1200)
        self.assertEqual(estimate("claude-opus-5.5", 3.0, 1.0, 4, input=1200)["cache_read_tokens"], 0)
        guess = estimate("claude-opus-5.5", 3.0, hit, 4, output=2000)
        self.assertEqual((guess["output_tokens"], guess["input_tokens"]), (2000, 28000))

    def test_zero_input_estimate_is_not_a_cache_hit(self):
        self.estimable("empty", .001, context=0.0)
        rate = query.query(self.db, "sess_root")["captures"]["estimates"]["cache_hit_rate"]
        self.assertIsNone(rate["percentage"])

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
        self.assertEqual(metrics["output_tokens"], query.metric(opus_tokens(80), 1, 1))  # .done is not recounted
        self.assertEqual(metrics["input_tokens"], query.metric(30000 - opus_tokens(80), 1, 1))

    def test_live_tool_and_reasoning_counts_win_over_retained_events(self):
        # The collector counted 60 chars live although the queue omitted most event copies; one stray copy survived.
        self.estimable("live", (74 * 3.0 + .5034) / 603)
        self.db.execute("UPDATE captures SET summary_json=? WHERE id='live'", (json.dumps({"output_text_chars": 0, "tool_chars": 40, "reasoning_chars": 20}),))
        self.db.execute("INSERT INTO events(capture_id,seq,event_name,data_json) VALUES ('live',0,'toolUseEvent',?)", (json.dumps({"input": "z" * 400}),))
        self.assertEqual(query.query(self.db, "sess_root")["captures"]["estimates"]["output_tokens"], query.metric(opus_tokens(60), 1, 1))

    def completed(self, ident, output, deltas=()):
        events = [*deltas, ("response.completed", {"type": "response.completed", "response": {"output": output}})]
        self.db.executemany("INSERT INTO events(capture_id,seq,event_name,data_json) VALUES (?,?,?,?)",
                            [(ident, seq, name, json.dumps(data)) for seq, (name, data) in enumerate(events)])

    def test_terminal_only_tool_and_reasoning_output_counts_once(self):
        self.estimable("terminal", (74 * 3.0 + .5034) / 603)
        self.completed("terminal", [{"type": "function_call", "name": "shell", "arguments": "x" * 400}])
        self.assertEqual(query.query(self.db, "sess_root")["captures"]["estimates"]["output_tokens"], query.metric(opus_tokens(400), 1, 1))
        # A repeated completed event is the same output, not twice as much.
        self.db.execute("INSERT INTO events(capture_id,seq,event_name,data_json) SELECT capture_id,seq+100,event_name,data_json FROM events WHERE capture_id='terminal'")
        self.assertEqual(query.query(self.db, "sess_root")["captures"]["estimates"]["output_tokens"], query.metric(opus_tokens(400), 1, 1))
        # Deltas present: their terminal copies are not recounted; terminal-only reasoning still counts.
        self.db.execute("DELETE FROM captures")
        self.db.execute("DELETE FROM events")
        self.estimable("mixed", (74 * 3.0 + .5034) / 603)
        self.completed("mixed", [{"type": "function_call", "arguments": "x" * 40},
                                 {"type": "reasoning", "content": [{"type": "reasoning_text", "text": "y" * 20}]}],
                       [("response.function_call_arguments.delta", {"type": "response.function_call_arguments.delta", "delta": "x" * 40})])
        self.assertEqual(query.query(self.db, "sess_root")["captures"]["estimates"]["output_tokens"], query.metric(opus_tokens(60), 1, 1))

    def test_estimator_refuses_unknown_inputs(self):
        estimate = query.credit_discount.estimate
        self.assertIsNone(estimate("other-model", 3.0, 1, 0))
        self.assertIsNone(estimate("claude-opus-5.5", None, 1, 0))
        self.assertEqual(estimate("claude-opus-5.5", 3.0, None, 8), {"total_tokens": 30000, "input_tokens": 30000 - opus_tokens(8),
                                                                     "output_tokens": opus_tokens(8), "cache_read_tokens": None,
                                                                     "cache_read_error": None})
        self.assertEqual(estimate("claude-opus-5.5", 3.0, 1, None)["output_tokens"], None)
        # Interrupted capture: exact input, no output count or characters; no cache split.
        self.assertEqual(estimate("claude-opus-5.5", 3.0, 1, None, input=1200),
                         {"total_tokens": 30000, "input_tokens": 1200, "output_tokens": None, "cache_read_tokens": None,
                          "cache_read_error": None})
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
        self.assertRegex(query.render_summary(report), r"\n⚠ (.*; )?1 multi-metered call$")
        report["captures"]["multiple_metering_events"] = 2
        self.assertRegex(query.render_summary(report), r"\n⚠ (.*; )?2 multi-metered calls$")
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
