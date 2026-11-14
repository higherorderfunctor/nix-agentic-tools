"""Check saved Reader normalization without credentials or live collection.

The owner check runs generated typed inputs through the JSON boundary; literal
cases pin producer spelling and failure isolation without snapshot inventories.
"""

import datetime as dt
import json
from pathlib import Path
import runpy
import sys
import types
import unittest

from hypothesis import given, settings, strategies as st
from pydantic import TypeAdapter, ValidationError

# Allow the owner check to supply its packaged scripts directory.
SCRIPTS = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "scripts"
# Load the standalone normalizer without installing it as a Python package.
N = types.SimpleNamespace(**runpy.run_path(str(SCRIPTS / "usage-normalize.py")))
# Keep generated cases reproducible offline without a persistent example database.
settings.register_profile("offline", database=None, deadline=None, max_examples=60)
settings.load_profile("offline")
# Fix the replay clock so tests never depend on wall time.
NOW = "2026-11-12T01:35:00Z"
# Pin the independent Unix-second expectation for the replay clock.
EPOCH = 1794447300
# Distinguish canonical identities from served model spellings.
ROUTES = [
    N.Route(id="canonical-a", maker=None, model="served-fable"),
    N.Route(id="canonical-b", maker="synthetic", model="fable"),
]


def iso(seconds, offset=0):
    """Generate equivalent offset timestamps for replay and boundary assertions."""
    return dt.datetime.fromtimestamp(seconds, dt.timezone(dt.timedelta(minutes=offset))).isoformat()


@st.composite
def windows(draw):
    """Generate consistent quantities and resets across varied window durations."""
    remaining = draw(st.integers(0, 100))
    duration = draw(st.integers(2, 2678400))
    return N.Window(
        remainingPercent=remaining, usedPercent=100 - remaining,
        windowSeconds=duration, resetsAt=iso(EPOCH + duration), status="active",
    )


# Exercise native capacities and both roles without copying production configuration.
specs = st.builds(
    N.LimitSpec, capacity=st.integers(1, 100000), models=st.just(["canonical-a"]),
    role=st.sampled_from(["gate", "pace"]), unit=st.sampled_from(["USD", "percentagePoint"]),
    window=st.just("7d:fable"),
)


def snapshot(spec=None, window=None):
    """Build a minimal valid capture whose independent components tests can corrupt."""
    spec = spec or N.LimitSpec(capacity=40, models=["canonical-a"], role="pace", unit="USD", window="7d:fable")
    window = window or N.Window(remainingPercent=75, usedPercent=25, windowSeconds=604800,
                                resetsAt="2026-11-18T01:35:00Z", status="active")
    envelope = N.Envelope(
        account=N.Account(auth_index=None, name=None, plan=None), pool="reader",
        windows={spec.window: window.model_dump(mode="json", exclude_unset=True)},
    )
    capture = N.Capture(exit=0, finishedAt=NOW, data=envelope.model_dump(mode="json", exclude_unset=True))
    return N.Snapshot(
        pools={"budget": N.Registration(readerPool="reader", limits={"allowance": spec})},
        readers={"budget": capture.model_dump(mode="json", exclude_unset=True)},
        routes=ROUTES, runtime="offline",
    ).model_dump(mode="json", exclude_unset=True)


def limit(result):
    """Select the synthetic registered slot for focused allowance assertions."""
    return result["pools"]["budget"]["limits"][0]


def reasons(result):
    """Compare safe diagnostic codes independently of diagnostic ordering."""
    return {item["reason"] for item in result["diagnostics"]}


class Observations(unittest.TestCase):
    """Protect normalization, failure isolation and private-data projection at the boundary."""
    @given(st.sampled_from([" reader", "reader ", "\treader\n"]))
    def test_pool_identity_matches_verbatim(self, pool):
        """Whitespace cannot turn a different Reader pool into the registered pool."""
        value = snapshot()
        value["readers"]["budget"]["data"]["pool"] = pool
        result = N.normalize(value, NOW)
        self.assertIn("pool-mismatch", reasons(result))
        self.assertEqual((limit(result)["status"], limit(result)["remaining"]), ("missing", None))
        self.assertFalse(result["pools"]["budget"]["scopeResolved"])

    @given(specs, windows())
    def test_native_amounts_roles_and_resets(self, spec, window):
        """Capacity scales percentages without changing the declared unit or role."""
        result = limit(N.normalize(snapshot(spec, window), NOW))
        self.assertAlmostEqual(result["remaining"], spec.capacity * window.remainingPercent / 100)
        self.assertAlmostEqual(result["used"], spec.capacity * window.usedPercent / 100)
        self.assertEqual((result["role"], result["unit"], result["status"]), (spec.role, spec.unit, "valid"))
        self.assertEqual(result["windowSeconds"], window.windowSeconds)
        self.assertEqual(result["naturalResetAt"], EPOCH + window.windowSeconds)
        self.assertEqual(result["gateOpensAt"], EPOCH + window.windowSeconds
                         if spec.role == "gate" and window.remainingPercent == 0 else None)

    @given(st.integers(-720, 840), st.integers(0, 999999))
    def test_iso_offsets_and_capture_fractions(self, offset, microsecond):
        """Equivalent offset clocks replay identically and capture fractions truncate."""
        value = snapshot()
        instant = dt.datetime.fromisoformat(iso(EPOCH, offset)).replace(microsecond=microsecond).isoformat()
        value["readers"]["budget"]["finishedAt"] = instant
        first = N.normalize(value, instant)
        self.assertEqual(first, N.normalize(value, NOW))
        self.assertEqual((first["asOf"], limit(first)["observedAt"]), (EPOCH, EPOCH))

    def test_timestamp_boundary_has_one_text_contract(self):
        """Reader ISO timestamps require an offset; no producer supplies epoch input."""
        for raw in [EPOCH, float(EPOCH), str(EPOCH), "2026-11-12T01:35:00", True]:
            with self.subTest(raw=raw), self.assertRaises(ValidationError):
                TypeAdapter(N.Timestamp).validate_python(raw)
        self.assertEqual(int(TypeAdapter(N.Timestamp).validate_python("2026-11-11T18:35:00-07:00").timestamp()), EPOCH)

    @given(st.integers(1, 8))
    def test_unknown_scope_counts_do_not_expand_models(self, count):
        """Exact registrations preserve canonical ids and refuse unknown scope expansion."""
        value = snapshot()
        value["readers"]["budget"]["data"]["windows"].update({f"7d:private-{i}": {} for i in range(count)})
        result = N.normalize(value, NOW)
        self.assertEqual(limit(result)["models"], ["canonical-a"])
        self.assertFalse(result["pools"]["budget"]["scopeResolved"])
        self.assertIn({"pool": "budget", "reason": "unregistered-window", "count": count}, result["diagnostics"])
        self.assertNotIn("private-", json.dumps(result))

    @given(st.sampled_from(["gate", "pace"]), st.integers(0, 100))
    def test_absent_reset_depends_on_idle_or_open_gate(self, role, remaining):
        """Only idle windows and positive gates may omit their natural reset."""
        value = snapshot()
        value["pools"]["budget"]["limits"]["allowance"]["role"] = role
        value["readers"]["budget"]["data"]["windows"]["7d:fable"].update(
            remainingPercent=remaining, usedPercent=100 - remaining, resetsAt=None)
        result = limit(N.normalize(value, NOW))
        self.assertEqual(result["status"], "valid" if remaining == 100 or role == "gate" and remaining > 0 else "invalid")
        self.assertIsNone(result["naturalResetAt"])
        self.assertIsNone(result["gateOpensAt"])

    def test_literal_calendar_rounding_and_staleness(self):
        """Calendar duration stays native; rounding allows one second and stale zero stays zero."""
        value = snapshot()
        window = value["readers"]["budget"]["data"]["windows"]["7d:fable"]
        window.update(remainingPercent=0, usedPercent=100, windowSeconds=2678400)
        for seconds, status in [(2678401, "valid"), (2678402, "invalid"), (0, "stale")]:
            window["resetsAt"] = iso(EPOCH + seconds)
            result = limit(N.normalize(value, NOW))
            self.assertEqual((result["status"], result["remaining"], result["naturalResetAt"]), (status, 0, EPOCH + seconds))
        window["resetsAt"] = iso(EPOCH + 2678400)
        for age, status in [(3600, "valid"), (3601, "stale")]:
            self.assertEqual(limit(N.normalize(value, iso(EPOCH + age)))["status"], status)

    @given(st.sampled_from(["finishedAt", "resetsAt", "windowSeconds"]),
           st.sampled_from([None, True, "private-invalid", {}, []]))
    def test_bad_timing_preserves_measured_zero(self, field, bad):
        """Independent timing failures cannot erase measured exhaustion or leak payloads."""
        value = snapshot()
        capture = value["readers"]["budget"]
        window = capture["data"]["windows"]["7d:fable"]
        window.update(remainingPercent=0, usedPercent=100)
        (capture if field == "finishedAt" else window)[field] = bad
        result = N.normalize(value, NOW)
        self.assertEqual((limit(result)["remaining"], limit(result)["used"], limit(result)["status"]), (0, 40, "invalid"))
        self.assertNotIn("private-", json.dumps(result))

    @given(st.sampled_from(["balances", "bonuses"]),
           st.sampled_from([None, {}, "private-extra", [{"kind": "private-kind"}]]))
    def test_bad_extras_preserve_allowance(self, field, bad):
        """Malformed optional arrays cannot erase a valid independent allowance."""
        value = snapshot()
        value["readers"]["budget"]["data"][field] = bad
        result = N.normalize(value, NOW)
        self.assertEqual((limit(result)["remaining"], limit(result)["status"]), (30, "valid"))
        self.assertIn("invalid-extras", reasons(result))
        self.assertNotIn("private-", json.dumps(result))

    def test_absent_and_empty_extras_are_distinct(self):
        """Absent extras are unknown while explicit empty arrays are known empty."""
        value = snapshot()
        metadata = N.normalize(value, NOW)["pools"]["budget"]["readerMetadata"]
        self.assertEqual(metadata, {"balances": None, "bonuses": None})
        value["readers"]["budget"]["data"].update(balances=[], bonuses=[])
        result = N.normalize(value, NOW)
        self.assertEqual(result["pools"]["budget"]["readerMetadata"], {"balances": [], "bonuses": []})
        self.assertNotIn("invalid-extras", reasons(result))

    @given(st.integers(min_value=0), st.sampled_from([-1, 0.5, True, "2", None]))
    def test_bonus_counts_are_whole_and_nonnegative(self, count, invalid):
        """Whole nonnegative counts survive while invalid siblings are omitted independently."""
        value = snapshot()
        bonus = N.Bonus(count=count, expiresAt=None, kind="promo_credits").model_dump(mode="json")
        value["readers"]["budget"]["data"]["bonuses"] = [bonus, {**bonus, "count": invalid}]
        result = N.normalize(value, NOW)
        self.assertEqual(result["pools"]["budget"]["readerMetadata"]["bonuses"],
                         [{"count": count, "expiresAt": None, "kind": "promo_credits"}])
        self.assertIn("invalid-extras", reasons(result))
        self.assertEqual(limit(result)["remaining"], 30)

    def test_private_account_fields_are_not_projected(self):
        """Non-null account identity fields remain private even in successful captures."""
        value = snapshot()
        value["readers"]["budget"]["data"]["account"] = {
            "auth_index": "private-auth", "name": "private-name", "plan": "private-plan"}
        result = N.normalize(value, NOW)
        self.assertEqual((limit(result)["remaining"], limit(result)["status"]), (30, "valid"))
        self.assertNotIn("private-", json.dumps(result))

    @given(st.sampled_from(["credits", "extra_usage"]), st.sampled_from(["credits", "USD"]))
    def test_balance_kind_unit_pairs(self, kind, unit):
        """Only the two producer kind/unit pairs survive metadata projection."""
        value = snapshot()
        value["readers"]["budget"]["data"]["balances"] = [
            {"kind": kind, "unit": unit, "remaining": 7, "expiresAt": None}]
        result = N.normalize(value, NOW)
        allowed = (kind, unit) in {("credits", "credits"), ("extra_usage", "USD")}
        self.assertEqual(result["pools"]["budget"]["readerMetadata"]["balances"],
                         [{"kind": kind, "unit": unit, "remaining": 7, "expiresAt": None}] if allowed else [])
        self.assertEqual("invalid-extras" in reasons(result), not allowed)
        self.assertEqual((limit(result)["remaining"], limit(result)["status"]), (30, "valid"))

    def test_literal_metadata_allowlist(self):
        """Known extras retain native values while invalid siblings and secrets disappear."""
        value = snapshot()
        value["readers"]["budget"]["data"].update(
            balances=[{"kind": "credits", "unit": "credits", "remaining": 12, "expiresAt": None, "secret": "private"},
                      {"kind": "extra_usage", "unit": "USD", "remaining": 7, "expiresAt": NOW}],
            bonuses=[{"kind": "rate_limit_reset", "count": 2, "expiresAt": NOW}, {"kind": "private"}],
        )
        result = N.normalize(value, NOW)
        self.assertEqual(result["pools"]["budget"]["readerMetadata"], {
            "balances": [{"kind": "credits", "unit": "credits", "remaining": 12, "expiresAt": None},
                         {"kind": "extra_usage", "unit": "USD", "remaining": 7, "expiresAt": EPOCH}],
            "bonuses": [{"kind": "rate_limit_reset", "count": 2, "expiresAt": EPOCH}],
        })
        self.assertNotIn("private", json.dumps(result))

    @given(st.sampled_from([
        ({"exit": 7, "stdout": "private"}, "exit-nonzero"),
        ({"exit": True}, "invalid-exit-status"),
        ({"stdout": "{}{}"}, "invalid-json"),
        ({"data": {}}, "invalid-envelope"),
        ({"data": {"account": {"auth_index": None, "name": None, "plan": None}, "pool": "wrong", "windows": {}}}, "pool-mismatch"),
    ]))
    def test_failed_captures_keep_routes_and_slots(self, case):
        """Capture failures keep declared routes and limit slots without exposing payloads."""
        patch, reason = case
        value = snapshot()
        value["readers"]["budget"].update(patch, stderr="private")
        result = N.normalize(value, NOW)
        self.assertEqual(result["routes"], [
            {"id": "canonical-a", "maker": None, "model": "served-fable"},
            {"id": "canonical-b", "maker": "synthetic", "model": "fable"},
        ])
        self.assertEqual((limit(result)["id"], limit(result)["status"]), ("allowance", "missing"))
        self.assertIn(reason, reasons(result))
        self.assertFalse(result["pools"]["budget"]["scopeResolved"])
        self.assertNotIn("private", json.dumps(result))

    @given(windows())
    def test_stdout_and_decoded_replay_agree(self, window):
        """JSON captures and decoded captures produce the same deterministic facts."""
        value = snapshot(window=window)
        expected = N.normalize(value, NOW)
        capture = value["readers"]["budget"]
        capture["stdout"] = json.dumps(capture.pop("data"))
        self.assertEqual(N.normalize(value, NOW), expected)
        capture["data"] = {"private": "ignored because stdout takes precedence"}
        self.assertEqual(N.normalize(value, NOW), expected)

    @given(st.integers(201, 1500))
    def test_json_depth_is_bounded(self, depth):
        """Excessive JSON nesting becomes a safe parse failure before envelope validation."""
        value = snapshot()
        value["readers"]["budget"]["stdout"] = "[" * depth + "0" + "]" * depth
        result = N.normalize(value, NOW)
        self.assertIn("invalid-json", reasons(result))
        self.assertEqual(limit(result)["status"], "missing")

    def test_json_depth_boundary(self):
        """The library accepts 200 nested arrays and rejects the next level."""
        parsed = N.from_json("[" * 200 + "0" + "]" * 200)
        for _ in range(200):
            self.assertEqual(len(parsed), 1)
            parsed = parsed[0]
        self.assertEqual(parsed, 0)
        with self.assertRaises(ValueError):
            N.from_json("[" * 201 + "0" + "]" * 201)

    @given(st.one_of(
        st.sampled_from(["active", "critical", "estimated", "normal", "ok", "warning", None]),
        st.text().filter(lambda status: status not in {"active", "critical", "estimated", "normal", "ok", "warning"}),
    ))
    def test_status_controls_enforcement_only(self, status):
        """Unknown enforcement leaves valid measured allowance available for inspection."""
        value = snapshot()
        value["readers"]["budget"]["data"]["windows"]["7d:fable"]["status"] = status
        result = limit(N.normalize(value, NOW))
        self.assertEqual((result["readerStatus"], result["remaining"], result["status"]), (status, 30, "valid"))
        self.assertEqual(result["enforced"], True if status in {"active", "critical", "estimated", "normal", "ok", "warning"} else None)

    @given(st.sampled_from([True, [], {"secret": "private-status"}]))
    def test_malformed_status_preserves_allowance(self, bad):
        """A malformed status cannot erase quantities or expose a non-scalar payload."""
        value = snapshot()
        value["readers"]["budget"]["data"]["windows"]["7d:fable"]["status"] = bad
        result = N.normalize(value, NOW)
        self.assertEqual((limit(result)["remaining"], limit(result)["status"]), (30, "invalid"))
        self.assertIsNone(limit(result)["readerStatus"])
        self.assertIn("invalid-status", reasons(result))
        self.assertNotIn("private-", json.dumps(result))

    @given(st.sampled_from([True, -1, 101, "private-quantity", float("nan")]))
    def test_malformed_quantity_keeps_independent_window(self, bad):
        """A bad quantity invalidates its window while an independent window stays measured."""
        value = snapshot()
        limits = value["pools"]["budget"]["limits"]
        limits["other"] = {**limits["allowance"], "window": "monthly"}
        windows = value["readers"]["budget"]["data"]["windows"]
        windows["monthly"] = windows["7d:fable"].copy()
        windows["7d:fable"]["remainingPercent"] = bad
        result = N.normalize(value, NOW)
        broken, independent = result["pools"]["budget"]["limits"]
        self.assertEqual((broken["status"], broken["remaining"]), ("invalid", None))
        self.assertEqual((independent["status"], independent["remaining"]), ("valid", 30))
        self.assertNotIn("private-", json.dumps(result))

    def test_missing_and_future_capture(self):
        """Missing captures keep slots; future capture times preserve independently measured amounts."""
        value = snapshot()
        value["readers"]["budget"]["finishedAt"] = "2026-11-12T01:35:01Z"
        result = N.normalize(value, NOW)
        self.assertIn("future-observation", reasons(result))
        self.assertEqual((limit(result)["remaining"], limit(result)["status"]), (30, "invalid"))
        value["readers"].clear()
        result = N.normalize(value, NOW)
        self.assertIn("missing-capture", reasons(result))
        self.assertEqual((limit(result)["remaining"], limit(result)["status"]), (None, "missing"))

    def test_invalid_registration_is_refused(self):
        """Unknown canonical ids, duplicate windows and invented limit fields fail at input."""
        for patch, error in [({"models": ["served-fable"]}, "unknown-model"), ({"resetPolicy": "use"}, "extra_forbidden")]:
            value = snapshot()
            value["pools"]["budget"]["limits"]["allowance"].update(patch)
            with self.assertRaisesRegex(ValidationError, error):
                N.normalize(value, NOW)
        value = snapshot()
        limits = value["pools"]["budget"]["limits"]
        limits["duplicate"] = limits["allowance"].copy()
        with self.assertRaisesRegex(ValidationError, "duplicate-window-registration"):
            N.normalize(value, NOW)


if __name__ == "__main__":
    unittest.main(verbosity=2)
