"""Sanitized numeric calibration and offline evidence-gating regressions."""

import gzip
import json
from pathlib import Path
import re
import unittest
from unittest.mock import patch

from capture import digest
import credit_discount as discount
import test_query
import query


FIXTURE = json.loads((Path(__file__).parent / "fixtures/credit-discount.json").read_text())
RETAINED = gzip.compress(b"retained")  # a real gzip payload, so the sealed subTest can read and seal it


class DiscountTests(unittest.TestCase):
    def test_profile_refuses_unsupported_or_unproved_inputs(self):
        # Each row changes only one fact, so its own restriction must reject it.
        facts = FIXTURE[0]
        self.assertEqual(discount.classify(facts)["classification"], "baseline")
        for field, value, reason in (
            ("chars", None, "unsupported_output_length"),  # missing count is not a comparison operand
            ("chars", 0, "unsupported_output_length"),  # an empty response is not measured
            ("chars", 6, "unsupported_output_length"),  # just above the fitted length
            ("complete", False, "incomplete_capture"),
            ("context", None, "invalid_context"),
            ("context", .8, "context_outside_calibration"),  # do not extrapolate down
            ("context", 4, "context_outside_calibration"),  # do not extrapolate up
            ("credits", None, "invalid_credits"),
            ("credits", float("inf"), "invalid_credits"),
            ("effort", None, "unsupported_effort"),  # do not infer the effort
            ("effort", "high", "unsupported_effort"),
            ("model", None, "unsupported_model"),  # do not infer the model
        ):
            with self.subTest(field=field, value=value):
                self.assertEqual(discount.classify({**facts, field: value}),
                                 {"classification": "excluded", "reason": reason})

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
        # Known full-hit and full-miss prices for 1.8% context; tolerance is one millionth of a credit.
        hit, miss = .0606915422885572, .2217303482587065
        for case, credits, expected, residual, score in (
            ("hit", hit, "discount_like", -.1610388059701493, 1),
            ("hit beyond tolerance", hit - .000002, "anomaly", -.1610408059701493, "above one"),
            ("hit within tolerance", hit - .0000005, "discount_like", -.1610393059701493, None),
            ("miss", miss, "baseline", 0, 0),
            ("miss beyond tolerance", miss + .000002, "anomaly", .000002, None),
            ("miss within tolerance", miss + .0000005, "baseline", .0000005, None),
        ):
            with self.subTest(case=case):
                result = discount.classify({**FIXTURE[0], "context": 1.8, "credits": credits})
                self.assertEqual(result["classification"], expected)
                self.assertAlmostEqual(result["baseline_residual"], residual, places=12)
                if score == "above one":
                    self.assertGreater(result["raw_discount_score"], 1)
                elif score is not None:
                    self.assertAlmostEqual(result["raw_discount_score"], score)


class ModelFactsTests(unittest.TestCase):
    MODEL = "claude-sonnet-4.6"
    # Synthetic prices keep these estimator checks independent of a rate refit.
    RATES = {"fixed_per_call": .01, "hit_input": .000001, "miss_input": .000011, "output": .001}

    def test_windows_come_from_the_snapshot_without_routers(self):
        self.assertIn("auto", discount.FACTS["models"])
        self.assertNotIn("auto", discount.WINDOWS)
        self.assertEqual(discount.WINDOWS["claude-sonnet-4.5"], 200_000)
        self.assertIsNone(discount.estimate("auto", 3.0, 1, 8))

    def test_unbilled_tokens_are_never_cached(self):
        """A full hit on 29,998 input tokens, 2,400 of them unbilled, caches the 27,598 billed ones."""
        rates = {**self.RATES, "chars_per_token": 4, "unbilled_tokens": 2400}
        self.assertAlmostEqual(discount.price(rates, 29_998, 2, 29_998), .039598)
        with patch.dict(discount.RATES, {self.MODEL: rates}):
            self.assertEqual(discount.estimate(self.MODEL, 3.0, .039598, 8)["cache_read_tokens"], 27_598)

    def test_output_guess_uses_the_fitted_chars_per_token_else_the_default(self):
        # For the same eight characters, a fitted ratio of two doubles the default output guess.
        for rates, miss, input_tokens, output_tokens in (
            (self.RATES, .341978, 29_998, 2),
            ({**self.RATES, "chars_per_token": 2}, .343956, 29_996, 4),
        ):
            with self.subTest(output_tokens=output_tokens), patch.dict(discount.RATES, {self.MODEL: rates}):
                self.assertEqual(discount.estimate(self.MODEL, 3.0, miss, 8),
                                 {"total_tokens": 30_000, "input_tokens": input_tokens, "output_tokens": output_tokens,
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
        self.db.execute("UPDATE captures SET request_gzip=?,request_sha256=?,context_usage_percentage=?,transport_ended=1,dropped_bytes=0,dropped_chunks=0,summary_json=? WHERE id=?",
                        (RETAINED, digest(b"retained"), facts["context"], json.dumps({"output_text_chars": facts["chars"], "terminal": "response.completed", "output_count_source": "terminal_output"}), ident))
        output = [{"type": "message", "content": [{"type": "output_text", "text": "x" * facts["chars"]}]}]
        if extra_output:
            output.append(extra_output)
        terminal = {"type": "response.completed", "response": {"output": output}}
        self.db.execute("INSERT INTO events(capture_id,seq,event_name,frame_gzip,data_json) VALUES (?,0,'response.completed',?,?)",
                        (ident, RETAINED, json.dumps(terminal)))
        self.db.execute("INSERT INTO chunks(capture_id,seq,application_gzip) VALUES (?,0,?)", (ident, RETAINED))
        return ident

    def test_scalar_exclusions_never_query_event_proof(self):
        self.add({**FIXTURE[0], "label": "unsupported", "model": "other"})
        self.add({**FIXTURE[0], "label": "long", "chars": 691})
        statements = []
        self.db.set_trace_callback(statements.append)
        report = query.query(self.db, "sess_root")
        self.assertEqual(report["captures"]["credit_discount"]["exclusion_reasons"],
                         {"unsupported_model": 1, "unsupported_output_length": 1})
        self.assertFalse(any("AS no_reasoning_tools" in statement for statement in statements))

    def test_query_aggregation_preserves_unknown_tokens_and_separate_hit_counter(self):
        for index, facts in enumerate(FIXTURE):
            self.add(facts, "root" if index % 2 else "child")
        report = query.query(self.db, "sess_root", "tree")
        captures = report["captures"]
        diagnostic = captures["credit_discount"]
        self.assertEqual({key: diagnostic[key] for key in ("requests", "eligible", "discount_like", "baseline", "excluded", "anomaly", "percentage")},
                         {"anomaly": 0, "baseline": 3, "discount_like": 5, "eligible": 8, "excluded": 2,
                          "percentage": 62.5, "requests": 10})
        self.assertEqual({item["capture_id"]: item["classification"] for item in diagnostic["diagnostics"]}, {
            "conversation_1": "discount_like", "conversation_2": "discount_like", "conversation_3": "discount_like",
            "medium_cold": "baseline", "medium_delayed": "baseline", "medium_warm": "discount_like",
            "size_long": "baseline", "size_short": "discount_like",
        })
        self.assertEqual({name: pool["credit_discount"]["eligible"] for name, pool in captures["pools"].items()},
                         {"other_linked_conversations": 4, "root_conversation": 4, "unknown": 0})
        self.assertEqual(captures["models"][0]["credit_discount"]["percentage"], 62.5)
        for name in ("input_tokens", "output_tokens", "cache_read_tokens", "total_tokens"):
            self.assertIsNone(captures["metrics"][name]["observed_sum"])
        self.assertIsNone(captures["cache_hit_rate"]["percentage"])
        output = query.render(report)
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
                        (ident, RETAINED, json.dumps(second)))
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
        # One exact-scope capture per evidence failure; the same eligible capture with no changes is the control.
        for case, reason, extra_output, mutation in (
            ("control", None, None, None),
            ("delta-count", "missing_or_ambiguous_terminal", None,
             "UPDATE captures SET summary_json=json_set(summary_json,'$.output_count_source','deltas') WHERE id=?"),
            ("missing-chunk", "missing_retained_evidence", None, "DELETE FROM chunks WHERE capture_id=?"),
            ("missing-frame", "missing_retained_evidence", None, "UPDATE events SET frame_gzip=NULL WHERE capture_id=?"),
            ("reasoning-delta", "reasoning_or_tool_output", None,
             ("response.reasoning.delta", '{"type":"response.reasoning.delta"}')),
            ("terminal-reasoning", "unproved_text_only_output", {"type": "reasoning", "summary": []}, None),
            ("tool-delta", "reasoning_or_tool_output", None,
             ("response.function_call_arguments.delta", '{"type":"response.function_call_arguments.delta"}')),
        ):
            with self.subTest(case=case):
                self.add({**FIXTURE[0], "label": case}, conversation=case, extra_output=extra_output)
                if isinstance(mutation, tuple):
                    event, data = mutation
                    self.db.execute("INSERT INTO events(capture_id,seq,event_name,frame_gzip,data_json) VALUES (?,1,?,?,?)",
                                    (case, event, RETAINED, data))
                elif mutation:
                    self.db.execute(mutation, (case,))
                report = query.query(self.db, "sess_" + case)
                diagnostic = report["captures"]["credit_discount"]
                if reason is None:
                    self.assertEqual(diagnostic["baseline"], 1)
                else:
                    self.assertEqual(diagnostic["exclusion_reasons"], {reason: 1})
                    self.assertNotIn("Discount", query.render_summary(report))


if __name__ == "__main__":
    unittest.main()
