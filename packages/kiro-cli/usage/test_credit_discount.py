"""Sanitized numeric calibration and offline evidence-gating regressions."""

import json
from pathlib import Path
import re
import unittest
from unittest.mock import patch

import credit_discount as discount
import test_query
import query


FIXTURE = json.loads((Path(__file__).parent / "fixtures/credit-discount.json").read_text())


class DiscountTests(unittest.TestCase):
    def test_initial_numeric_run(self):
        report = discount.aggregate()
        for row in FIXTURE:
            discount.add(report, discount.classify(row), row["label"])
        self.assertEqual((report["requests"], report["eligible"], report["discount_like"], report["baseline"], report["excluded"]), (10, 8, 5, 3, 2))
        self.assertEqual(report["percentage"], 62.5)
        self.assertEqual(report["anomaly"], 0)

    def test_profile_refuses_unsupported_or_unproved_inputs(self):
        for field, values in {"model": [None, "other"], "effort": [None, "high"],
                              "complete": [False, None], "retained": [False], "terminal": [False],
                              "text_only": [False], "no_reasoning_tools": [False], "chars": [None, 0, 6, True],
                              "context": [None, float("nan"), .8, 4], "credits": [None, float("inf")]}.items():
            for value in values:
                with self.subTest(field=field, value=value):
                    self.assertEqual(discount.classify({**FIXTURE[0], field: value})["classification"], "excluded")

    def test_aggregate_assumptions_are_isolated(self):
        first, second = discount.aggregate(), discount.aggregate()
        first["assumptions"].append("local annotation")
        self.assertNotIn("local annotation", second["assumptions"])
        self.assertNotIn("local annotation", discount.ASSUMPTIONS)

    def test_finite_extreme_credits_keep_derived_overflow_json_safe(self):
        for credits in (1e308, -1e308):
            result = discount.classify({**FIXTURE[0], "context": 1.8, "credits": credits})
            self.assertEqual(result["classification"], "anomaly")
            self.assertIsNone(result["raw_discount_score"])
            self.assertTrue(result["score_overflow"])
            self.assertEqual(result["baseline_residual"], credits)
            self.assertEqual(result["discounted_residual"], credits)
            json.dumps(result, allow_nan=False)
        normal = discount.classify(FIXTURE[0])
        self.assertFalse(normal["score_overflow"])
        json.dumps(normal, allow_nan=False)

    def test_curve_endpoints_numerical_tolerance_and_anomalies_are_not_clamped(self):
        facts = FIXTURE[0]
        baseline = (74 * facts["context"] + .5034) / 603
        hit = (20 * facts["context"] + .5970) / 603
        for credits, expected in ((baseline, "baseline"), (baseline + discount.EPSILON / 2, "baseline"),
                                  (hit, "discount_like"), (hit - discount.EPSILON / 2, "discount_like"),
                                  (hit - 2 * discount.EPSILON, "anomaly"), (baseline + 2 * discount.EPSILON, "anomaly")):
            result = discount.classify({**facts, "credits": credits})
            self.assertEqual(result["classification"], expected)
            self.assertAlmostEqual(result["baseline_residual"], credits - baseline)
        self.assertGreater(discount.classify({**facts, "credits": hit - 2 * discount.EPSILON})["raw_discount_score"], 1)
        self.assertLess(discount.classify({**facts, "credits": baseline + 2 * discount.EPSILON})["raw_discount_score"], 0)


class ModelFactsTests(unittest.TestCase):
    def test_windows_come_from_the_snapshot_without_routers(self):
        self.assertIn("auto", discount.FACTS["models"])
        self.assertNotIn("auto", discount.WINDOWS)
        self.assertEqual(discount.WINDOWS["claude-sonnet-4.5"], 200_000)
        self.assertIsNone(discount.estimate("auto", 3.0, 1, 8))

    def test_cached_error_scales_the_fitted_credit_error_by_credits(self):
        """A 10% credit error over the miss-hit spread; without credit_error the error is unknown."""
        rates = {**discount.RATES["claude-opus-5.5"], "credit_error": .1}
        with patch.dict(discount.RATES, {"claude-sonnet-4.6": rates}):
            self.assertAlmostEqual(discount.estimate("claude-sonnet-4.6", 3.0, .2, 8)["cache_read_error"],
                                   .1 * .2 / (rates["miss_input"] - rates["hit_input"]))
        unknown = {key: value for key, value in rates.items() if key != "credit_error"}
        with patch.dict(discount.RATES, {"claude-sonnet-4.6": unknown}):
            self.assertIsNone(discount.estimate("claude-sonnet-4.6", 3.0, .2, 8)["cache_read_error"])

    def test_unbilled_tokens_are_never_cached(self):
        """A full hit on 29,998 input tokens, 2,400 of them unbilled, caches the 27,598 billed ones."""
        rates = {**discount.RATES["claude-opus-5.5"], "chars_per_token": 4, "unbilled_tokens": 2400}
        hit = discount.price(rates, 29_998, 2, 29_998)
        self.assertAlmostEqual(hit, rates["fixed_per_call"] + rates["hit_input"] * 27_598 + rates["output"] * 2)
        with patch.dict(discount.RATES, {"claude-sonnet-4.6": rates}):
            self.assertEqual(discount.estimate("claude-sonnet-4.6", 3.0, hit, 8)["cache_read_tokens"], 27_598)

    def test_windowed_model_without_rates_has_no_cache_split(self):
        self.assertEqual(discount.estimate("claude-sonnet-4.6", 3.0, 1, 8),  # listed, never probed
                         {"total_tokens": 30000, "input_tokens": 29998, "output_tokens": 2, "cache_read_tokens": None,
                          "cache_read_error": None})

    def test_output_guess_uses_the_fitted_chars_per_token_else_the_default(self):
        """8 chars read 4 tokens at a fitted 2 chars per token and 2 at CHARS_PER_TOKEN; the cache split follows."""
        rates = {key: value for key, value in discount.RATES["claude-opus-5.5"].items()
                 if key not in ("chars_per_token", "credit_error")}
        for fitted, output in ((2, 4), (None, 8 // discount.CHARS_PER_TOKEN)):
            with self.subTest(fitted=fitted), patch.dict(discount.RATES, {"claude-sonnet-4.6": {
                    **rates, **({"chars_per_token": fitted} if fitted else {})}}):
                miss = discount.price(rates, 30_000 - output, output, 0)
                self.assertEqual(discount.estimate("claude-sonnet-4.6", 3.0, miss, 8),
                                 {"total_tokens": 30_000, "input_tokens": 30_000 - output, "output_tokens": output,
                                  "cache_read_tokens": 0, "cache_read_error": None})

class DiscountQueryTests(unittest.TestCase):
    def setUp(self):
        self.fixture = test_query.QueryTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.db = self.fixture.db

    def add(self, facts, conversation="root", extra_output=None):
        ident = facts["label"]
        self.fixture.captured(ident, conversation=conversation, credits=facts["credits"], tokens=None,
                              metadata={"model": facts["model"], "effort": facts["effort"], "kiro:root_conversation_id": "root"})
        self.db.execute("UPDATE captures SET request_gzip=?,context_usage_percentage=?,transport_ended=1,dropped_bytes=0,dropped_chunks=0,summary_json=? WHERE id=?",
                        (b"retained", facts["context"], json.dumps({"output_text_chars": facts["chars"], "terminal": "response.completed", "output_count_source": "terminal_output"}), ident))
        output = [{"type": "message", "content": [{"type": "output_text", "text": "x" * facts["chars"]}]}]
        if extra_output:
            output.append(extra_output)
        terminal = {"type": "response.completed", "response": {"output": output}}
        self.db.execute("INSERT INTO events(capture_id,seq,event_name,frame_gzip,data_json) VALUES (?,0,'response.completed',?,?)",
                        (ident, b"retained", json.dumps(terminal)))
        self.db.execute("INSERT INTO chunks(capture_id,seq,application_gzip) VALUES (?,0,?)", (ident, b"retained"))
        return ident

    def test_scalar_exclusions_never_query_event_proof(self):
        self.add({**FIXTURE[0], "label": "unsupported", "model": "other"})
        self.add({**FIXTURE[0], "label": "long", "chars": 691})
        statements = []
        self.db.set_trace_callback(statements.append)
        report = query.query(self.db, "sess_root")
        self.assertEqual(report["captures"]["credit_discount"]["excluded"], 2)
        self.assertFalse(any("AS no_reasoning_tools" in statement for statement in statements))

    def test_missing_chunk_or_terminal_counts_refuse_profile(self):
        ident = self.add(FIXTURE[0])
        self.db.execute("DELETE FROM chunks")
        self.assertEqual(query.query(self.db, "sess_root")["captures"]["credit_discount"]["exclusion_reasons"], {"missing_retained_evidence": 1})
        self.db.execute("INSERT INTO chunks(capture_id,seq,application_gzip) VALUES (?,0,?)", (ident, b"retained"))
        self.db.execute("UPDATE captures SET summary_json=?", (json.dumps({"output_text_chars": 5, "terminal": "response.completed", "output_count_source": "deltas"}),))
        self.assertEqual(query.query(self.db, "sess_root")["captures"]["credit_discount"]["exclusion_reasons"], {"missing_or_ambiguous_terminal": 1})

    def test_query_aggregation_preserves_unknown_tokens_and_separate_hit_counter(self):
        for index, facts in enumerate(FIXTURE):
            self.add(facts, "root" if index % 2 else "child")
        report = query.query(self.db, "sess_root", "tree")
        captures = report["captures"]
        self.assertEqual(captures["credit_discount"]["percentage"], 62.5)
        self.assertEqual(sum(pool["credit_discount"]["eligible"] for pool in captures["pools"].values()), 8)
        self.assertEqual(captures["models"][0]["credit_discount"]["percentage"], 62.5)
        for name in ("input_tokens", "output_tokens", "cache_read_tokens", "total_tokens"):
            self.assertIsNone(captures["metrics"][name]["observed_sum"])
        self.assertIsNone(captures["cache_hit_rate"]["percentage"])
        output = query.render(report)
        self.assertIn("Discount %", output)
        self.assertIn("~62.5% (8/10)", output)
        self.assertIn("not observed cache hits", output)
        output = query.render_summary(report)
        self.assertRegex(output, r"Cache hit  Discount\nclaude-opus-5.5\s+10\s+1.35\s+~146K\s+~241\s+~55.7K\s+~38%\s+~62%\n")
        for label, discount in (("Main", "50"), ("Sub/WF", "75"), ("Total", "62")):
            self.assertRegex(output, rf"\n{re.escape(label)}\s+\d+\s+[\d.]+\s+\S+\s+\S+\s+\S+\s+~\d+%\s+~{discount}%\n?")
        self.assertNotIn("not observed cache hits", output)
        self.db.execute("UPDATE captures SET cache_read_tokens=0,input_tokens=100,output_tokens=2")
        updated = query.query(self.db, "sess_root", "tree")["captures"]
        self.assertEqual(updated["cache_hit_rate"]["percentage"], 0)
        self.assertEqual(updated["metrics"]["input_tokens"]["observed_sum"], 1000)
        self.assertEqual(updated["credit_discount"]["percentage"], 62.5)

    def test_duplicate_terminal_is_ambiguous_without_changing_reported_counters(self):
        ident = self.add(FIXTURE[0])
        second = {"type": "response.completed", "response": {"output": [{"type": "reasoning", "summary": []}]}}
        self.db.execute("INSERT INTO events(capture_id,seq,event_name,frame_gzip,data_json) VALUES (?,1,'response.completed',?,?)",
                        (ident, b"retained", json.dumps(second)))
        captures = query.query(self.db, "sess_root")["captures"]
        self.assertEqual(captures["credit_discount"]["exclusion_reasons"], {"missing_or_ambiguous_terminal": 1})
        self.assertEqual(captures["metrics"]["credits"]["observed_sum"], FIXTURE[0]["credits"])
        self.assertIsNone(captures["metrics"]["input_tokens"]["observed_sum"])
        self.assertIsNone(captures["cache_hit_rate"]["percentage"])

    def test_legacy_database_without_events_or_chunks_has_no_profile_evidence(self):
        self.add(FIXTURE[0])
        self.db.executescript("DROP TABLE events; DROP TABLE chunks;")
        report = query.query(self.db, "sess_root")
        self.assertEqual(report["captures"]["credit_discount"]["exclusion_reasons"], {"missing_retained_evidence": 1})
        self.assertNotIn("Discount", query.render_summary(report))

    def test_anomaly_is_visible_without_fabricating_a_rate(self):
        self.add({**FIXTURE[0], "label": "anomaly", "credits": 1})
        report = query.query(self.db, "sess_root")
        diagnostic = report["captures"]["credit_discount"]
        self.assertEqual(diagnostic["anomaly"], 1)
        self.assertIsNone(diagnostic["percentage"])
        self.assertLess(diagnostic["diagnostics"][0]["raw_discount_score"], 0)
        self.assertEqual(diagnostic["diagnostics"][0]["capture_id"], "anomaly")
        output = query.render(report)
        self.assertIn("Discount %", output)
        self.assertIn("Profile anomalies: 1", output)
        self.assertRegex(output, r"claude-opus-5.5\s+1\s.*\s1.000000\s+—\n")  # Discount % stays unavailable
        self.assertRegex(query.render_summary(report), r"claude-opus-5.5\s+1\s+1.00\s+~18.0K\s+~2\s+~0\s+~0%\s+—\n")

    def test_retained_terminal_and_reasoning_proof_are_required(self):
        ident = self.add(FIXTURE[0], extra_output={"type": "reasoning", "summary": []})
        self.assertEqual(query.query(self.db, "sess_root")["captures"]["credit_discount"]["eligible"], 0)
        self.db.execute("DELETE FROM captures")
        self.db.execute("DELETE FROM events")
        self.db.execute("DELETE FROM chunks")
        ident = self.add(FIXTURE[0])
        self.db.execute("INSERT INTO events(capture_id,seq,event_name,frame_gzip,data_json) VALUES (?,1,'response.reasoning.delta',?,?)",
                        (ident, b"retained", '{"type":"response.reasoning.delta"}'))
        report = query.query(self.db, "sess_root")
        self.assertEqual(report["captures"]["credit_discount"]["eligible"], 0)
        self.assertNotIn("Discount", query.render_summary(report))
        self.db.execute("UPDATE events SET event_name=?,data_json=? WHERE seq=1", ("response.function_call_arguments.delta", json.dumps({"type": "response.function_call_arguments.delta"})))
        self.assertEqual(query.query(self.db, "sess_root")["captures"]["credit_discount"]["eligible"], 0)
        self.db.execute("DELETE FROM events WHERE seq=1")
        self.db.execute("UPDATE events SET frame_gzip=NULL")
        self.assertEqual(query.query(self.db, "sess_root")["captures"]["credit_discount"]["exclusion_reasons"], {"missing_retained_evidence": 1})


if __name__ == "__main__":
    unittest.main()
