"""Check saved Reader normalization without credentials or live collection."""

import datetime as dt
import json
from pathlib import Path
import runpy
import sys
import types
import unittest

from hypothesis import given, settings, strategies as st
from pydantic import ValidationError

SCRIPTS = Path(sys.argv.pop(1)) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "scripts"
N = types.SimpleNamespace(**runpy.run_path(str(SCRIPTS / "usage-normalize.py")))
settings.register_profile("offline", database=None, deadline=None, max_examples=60)
settings.load_profile("offline")
EPOCH = 1794447300
ROUTES = [
    N.Route(id="canonical-a", maker=None, model="served-fable"),
    N.Route(id="canonical-b", maker="synthetic", model="fable"),
]


def iso(seconds):
    return dt.datetime.fromtimestamp(seconds, dt.timezone.utc).isoformat()


@st.composite
def windows(draw):
    remaining = draw(st.integers(0, 100))
    duration = draw(st.integers(2, 2678400))
    return N.Window(remainingPercent=remaining, usedPercent=100 - remaining,
                    windowSeconds=duration, resetsAt=iso(EPOCH + duration), enforced=True)


specs = st.builds(
    N.LimitSpec, capacity=st.floats(1, 100000, allow_nan=False), models=st.just(["canonical-a"]),
    role=st.sampled_from(["gate", "pace"]), window=st.just("7d:fable"),
)


def snapshot(spec=None, window=None):
    spec = spec or N.LimitSpec(capacity=40, models=["canonical-a"], role="pace", window="7d:fable")
    window = window or N.Window(remainingPercent=75, usedPercent=25, windowSeconds=604800,
                                resetsAt="2026-11-18T01:35:00Z", enforced=True)
    envelope = N.Envelope(pool="reader", windows={spec.window: window.model_dump(mode="json", exclude_unset=True)})
    capture = N.Capture(exit=0, stdout=envelope.model_dump_json())
    return N.Snapshot(
        pools={"budget": N.Registration(readerPool="reader", limits={"allowance": spec})},
        readers={"budget": capture.model_dump(mode="json", exclude_unset=True)},
        routes=ROUTES,
    ).model_dump(mode="json", exclude_unset=True)


def normalize(value, now=EPOCH):
    return N.normalize(N.Snapshot.model_validate(value), now).model_dump(mode="json")


def limit(result):
    return result["pools"]["budget"]["limits"][0]


def envelope(value):
    return json.loads(value["readers"]["budget"]["stdout"])


def save_envelope(value, document):
    value["readers"]["budget"]["stdout"] = json.dumps(document)


class Observations(unittest.TestCase):
    @given(st.sampled_from([" reader", "reader ", "\treader\n"]))
    def test_pool_identity_matches_verbatim(self, pool):
        value = snapshot()
        document = envelope(value)
        document["pool"] = pool
        save_envelope(value, document)
        result = normalize(value)
        self.assertEqual((limit(result)["reason"], limit(result)["status"]), ("pool-mismatch", "missing"))
        self.assertFalse(result["pools"]["budget"]["scopeResolved"])

    @given(specs, windows())
    def test_native_amounts_roles_and_resets(self, spec, window):
        result = limit(normalize(snapshot(spec, window)))
        self.assertAlmostEqual(result["remaining"], spec.capacity * window.remainingPercent / 100)
        self.assertEqual((result["role"], result["status"]), (spec.role, "valid"))
        self.assertEqual(result["windowSeconds"], window.windowSeconds)
        self.assertEqual(result["naturalResetAt"], EPOCH + window.windowSeconds)

    @given(st.integers(1, 8))
    def test_unknown_scope_does_not_expand_models(self, count):
        value = snapshot()
        document = envelope(value)
        document["windows"].update({f"7d:private-{count}": {} for _ in range(count)})
        save_envelope(value, document)
        result = normalize(value)
        self.assertEqual(limit(result)["models"], ["canonical-a"])
        self.assertFalse(result["pools"]["budget"]["scopeResolved"])
        self.assertNotIn("private-", json.dumps(result))

    @given(st.sampled_from(["gate", "pace"]), st.integers(0, 100))
    def test_absent_reset_depends_on_idle_or_open_gate(self, role, remaining):
        value = snapshot()
        value["pools"]["budget"]["limits"]["allowance"]["role"] = role
        document = envelope(value)
        document["windows"]["7d:fable"].update(remainingPercent=remaining, usedPercent=100 - remaining, resetsAt=None)
        save_envelope(value, document)
        result = limit(normalize(value))
        expected = "valid" if remaining == 100 or role == "gate" and remaining > 0 else "invalid"
        expected_remaining = 0 if remaining == 0 else None if expected == "invalid" else remaining * 0.4
        self.assertEqual((result["status"], result["naturalResetAt"]), (expected, None))
        if expected_remaining is None:
            self.assertIsNone(result["remaining"])
        else:
            self.assertAlmostEqual(result["remaining"], expected_remaining)

    def test_expired_reset_is_stale(self):
        value = snapshot()
        document = envelope(value)
        document["windows"]["7d:fable"].update(remainingPercent=0, usedPercent=100, resetsAt=iso(EPOCH))
        save_envelope(value, document)
        result = limit(normalize(value))
        self.assertEqual((result["status"], result["remaining"], result["reason"]), ("stale", 0, "expired-reset"))

    def test_normalized_result_is_typed(self):
        result = N.normalize(N.Snapshot.model_validate(snapshot()), EPOCH)
        self.assertIsInstance(result, N.Normalized)
        self.assertIsInstance(result.pools["budget"], N.PoolEvidence)
        self.assertIsInstance(result.pools["budget"].limits[0], N.Observation)
        self.assertIsInstance(result.routes[0], N.Route)

    @given(st.sampled_from(["resetsAt", "windowSeconds"]),
           st.sampled_from([None, True, "private-invalid", {}, []]))
    def test_bad_window_timing_preserves_measured_zero(self, field, bad):
        value = snapshot()
        document = envelope(value)
        document["windows"]["7d:fable"].update(remainingPercent=0, usedPercent=100, **{field: bad})
        save_envelope(value, document)
        result = limit(normalize(value))
        self.assertEqual((result["remaining"], result["status"]), (0, "invalid"))
        self.assertIn(field, result["reason"])
        self.assertNotIn("private-", json.dumps(result))

    @given(st.sampled_from(["balances", "bonuses"]),
           st.sampled_from([None, {}, "private-extra", [{"kind": "private-kind"}]]))
    def test_bad_extras_preserve_allowance(self, field, bad):
        value = snapshot()
        document = envelope(value)
        document[field] = bad
        save_envelope(value, document)
        result = limit(normalize(value))
        self.assertEqual((result["remaining"], result["status"]), (30, "valid"))
        self.assertNotIn("private-", json.dumps(result))

    @given(st.sampled_from([
        ({"exit": 7, "stdout": "private"}, "exit-nonzero"),
        ({"exit": True}, "invalid-envelope"),
        ({"stdout": "{}{}"}, "invalid-json"),
        ({"stdout": "{}"}, "invalid-envelope"),
    ]))
    def test_failed_captures_keep_routes_and_slots(self, case):
        patch, reason = case
        value = snapshot()
        value["readers"]["budget"].update(patch, stderr="private")
        result = normalize(value)
        self.assertEqual(result["routes"], [route.model_dump() for route in ROUTES])
        self.assertEqual((limit(result)["reason"], limit(result)["status"]), (reason, "missing"))
        self.assertFalse(result["pools"]["budget"]["scopeResolved"])
        self.assertNotIn("private", json.dumps(result))

    @given(st.one_of(st.none(), st.booleans(), st.integers(), st.binary(),
                     st.lists(st.integers()), st.dictionaries(st.text(), st.integers())))
    def test_nontext_stdout_is_refused(self, stdout):
        value = snapshot()
        value["readers"]["budget"]["stdout"] = stdout
        result = normalize(value)
        self.assertEqual((limit(result)["reason"], limit(result)["status"]), ("invalid-envelope", "missing"))
        self.assertFalse(result["pools"]["budget"]["scopeResolved"])

    @given(st.integers(201, 1500))
    def test_json_depth_is_bounded(self, depth):
        value = snapshot()
        value["readers"]["budget"]["stdout"] = "[" * depth + "0" + "]" * depth
        result = normalize(value)
        self.assertEqual((limit(result)["reason"], limit(result)["status"]), ("invalid-json", "missing"))

    @given(st.sampled_from([True, -1, 101, "private-quantity", float("nan")]))
    def test_malformed_quantity_keeps_independent_window(self, bad):
        value = snapshot()
        value["pools"]["budget"]["limits"]["other"] = {**value["pools"]["budget"]["limits"]["allowance"], "window": "monthly"}
        document = envelope(value)
        document["windows"]["monthly"] = document["windows"]["7d:fable"].copy()
        document["windows"]["7d:fable"]["remainingPercent"] = bad
        save_envelope(value, document)
        broken, independent = normalize(value)["pools"]["budget"]["limits"]
        self.assertEqual((broken["status"], broken["remaining"]), ("invalid", None))
        self.assertEqual((independent["status"], independent["remaining"]), ("valid", 30))
        self.assertNotIn("private-", json.dumps(result) if (result := normalize(value)) else "")

    def test_invalid_registration_is_refused(self):
        for patch, error in [({"models": ["served-fable"]}, "unknown-model"), ({"resetPolicy": "use"}, "extra_forbidden")]:
            value = snapshot()
            value["pools"]["budget"]["limits"]["allowance"].update(patch)
            with self.assertRaisesRegex(ValidationError, error):
                normalize(value)
        value = snapshot()
        limits = value["pools"]["budget"]["limits"]
        limits["duplicate"] = limits["allowance"].copy()
        with self.assertRaisesRegex(ValidationError, "duplicate-window-registration"):
            normalize(value)


if __name__ == "__main__":
    unittest.main(verbosity=2)
