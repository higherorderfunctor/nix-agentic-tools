"""Offline Reader capture boundary; amounts retain their declared native units."""

import datetime as dt
import json
import math
from dataclasses import dataclass


def number(value):
    # Refuse booleans, negative quantities and non-finite numbers.
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < 0:
        raise ValueError("invalid-number")
    return value


def utc(value):
    # Normalize UTC timestamps and integer seconds without exposing parser text.
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    if not isinstance(value, str):
        raise ValueError("invalid-time")
    try:
        if value.isascii() and value.isdigit():
            return int(value)
        instant = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if instant.utcoffset() != dt.timedelta(0):
            raise ValueError("invalid-time")
        return int(instant.timestamp())
    except (OverflowError, ValueError):
        raise ValueError("invalid-time") from None


@dataclass(frozen=True)
class LimitSpec:
    # Hold a registered limit with explicit model scope and native capacity.
    capacity: float
    models: list[str]
    role: str
    unit: str
    window: str

    @classmethod
    def parse(cls, value):
        if not isinstance(value, dict) or set(value) != {"capacity", "models", "role", "unit", "window"}:
            raise ValueError("invalid-limit-spec")
        result = cls(**value)
        number(result.capacity)
        if result.capacity == 0 or result.unit not in {"percentagePoint", "USD"} or result.role not in {"gate", "pace"}:
            raise ValueError("invalid-limit-spec")
        if (
            not isinstance(result.window, str) or not result.window
            or not isinstance(result.models, list) or not result.models
            or any(not isinstance(m, str) or not m for m in result.models)
        ):
            raise ValueError("invalid-limit-spec")
        return result


def stdout_document(capture):
    # Decode captured stdout when supplied, refusing malformed JSON safely.
    document = capture.get("data")
    if "stdout" in capture:
        try:
            document = json.loads(capture["stdout"])
        except (RecursionError, TypeError, ValueError):
            raise ValueError("invalid-json") from None
    return document


class Invalid(ValueError):
    """Only locally assigned reason codes cross the diagnostic boundary."""


def envelope(capture):
    # Refuse envelopes missing account identity, pool identity or a window map.
    document = stdout_document(capture)
    if not isinstance(document, dict) or not isinstance(document.get("account"), dict):
        raise Invalid("invalid-envelope")
    account = document["account"]
    if any(k not in account or (account[k] is not None and not isinstance(account[k], str))
           for k in ("auth_index", "name", "plan")):
        raise Invalid("invalid-account")
    if (not isinstance(document.get("pool"), str) or not document["pool"].strip()
            or not isinstance(document.get("windows"), dict)):
        raise Invalid("invalid-envelope")
    return document


def count(value):
    # Bonus counts are whole nonnegative quantities.
    if type(value) is not int:
        raise ValueError("invalid-count")
    return number(value)


# Each extras array declares its identity fields, accepted identities and quantity parser.
EXTRAS = {
    "balances": (("kind", "unit"), {("credits", "credits"), ("extra_usage", "USD")}, "remaining", number),
    "bonuses": (("kind",), {("promo_credits",), ("rate_limit_reset",)}, "count", count),
}


def metadata(document, diagnostic):
    # Extras are inspection facts, not wallet balances or redemption rights.
    result = {}
    for field, (keys, identities, quantity, parse) in EXTRAS.items():
        items = document.get(field)
        result[field] = None
        if field not in document:
            continue
        if not isinstance(items, list):
            diagnostic("invalid-extras", component=field)
            continue
        result[field] = []
        for item in items:
            try:
                if tuple(item[key] for key in keys) not in identities:
                    raise ValueError
                clean = {key: item[key] for key in keys}
                clean[quantity] = parse(item[quantity])
                clean["expiresAt"] = None if item["expiresAt"] is None else utc(item["expiresAt"])
                result[field].append(clean)
            except (KeyError, TypeError, ValueError, OverflowError):
                diagnostic("invalid-extras", component=field)
    return result


# Known Reader statuses establish enforcement; other strings remain inspection facts.
ENFORCEMENT = dict.fromkeys(("active", "critical", "estimated", "normal", "ok", "warning"), True)


def window_observation(identifier, spec, window, observed, now, diagnostic):
    # Preserve measured quantities while validating timing and enforcement independently.
    result = dict(id=identifier, capacity=spec.capacity, unit=spec.unit,
                  role=spec.role, models=spec.models, remaining=None, used=None,
                  windowSeconds=None, naturalResetAt=None, enforced=None,
                  gateOpensAt=None, observedAt=observed, status="missing", readerStatus=None)
    if window is None:
        diagnostic("missing-window")
        return result
    if not isinstance(window, dict):
        diagnostic("invalid-window")
        result["status"] = "invalid"
        return result
    invalid = observed is None
    # Quantities survive independently invalid timing, including measured zero.
    try:
        remaining, used = number(window["remainingPercent"]), number(window["usedPercent"])
        if remaining > 100 or used > 100 or not math.isclose(remaining + used, 100):
            raise ValueError
        result.update(remaining=spec.capacity * (remaining / 100), used=spec.capacity * (used / 100))
    except (KeyError, TypeError, ValueError, OverflowError):
        diagnostic("invalid-quantity")
        invalid = True
    try:
        seconds = number(window["windowSeconds"])
        if not seconds:
            raise ValueError
        result["windowSeconds"] = seconds
    except (KeyError, TypeError, ValueError, OverflowError):
        diagnostic("invalid-duration")
        invalid = True
    try:
        reset = None if window["resetsAt"] is None else utc(window["resetsAt"])
        idle = result["used"] == 0 and result["remaining"] == spec.capacity
        open_gate = spec.role == "gate" and result["remaining"] is not None and result["remaining"] > 0
        if reset is None and not (idle or open_gate):
            raise ValueError
        result["naturalResetAt"] = reset
        # Reader resets may round up while capture seconds are truncated.
        if (reset is not None and observed is not None and result["windowSeconds"] is not None
                and reset - observed > result["windowSeconds"] + 1):
            raise ValueError
    except (KeyError, TypeError, ValueError, OverflowError):
        diagnostic("invalid-reset")
        invalid = True
    status = window.get("status")
    if "status" not in window or (status is not None and not isinstance(status, str)):
        diagnostic("invalid-status")
        invalid = True
    else:
        result["readerStatus"] = status
        result["enforced"] = ENFORCEMENT.get(status)
        if result["enforced"] is None:
            diagnostic("unknown-enforcement")
    reset = result["naturalResetAt"]
    stale = observed is not None and (now - observed > 3600 or (reset is not None and reset <= now))
    result["status"] = "invalid" if invalid else "stale" if stale else "valid"
    if result["status"] == "valid" and spec.role == "gate" and result["remaining"] == 0:
        result["gateOpensAt"] = reset
    return result


def snapshot_routes(snapshot):
    # Refuse malformed snapshots and routes before inspecting their captures.
    if (not isinstance(snapshot, dict) or not isinstance(snapshot.get("runtime"), str)
            or not snapshot["runtime"] or not isinstance(snapshot.get("pools"), dict)
            or not isinstance(snapshot.get("readers"), dict) or not isinstance(snapshot.get("routes"), list)):
        raise Invalid("invalid-snapshot")
    routes = snapshot["routes"]
    for route in routes:
        if (not isinstance(route, dict) or set(route) != {"id", "maker", "model"}
                or any(not isinstance(route[k], str) or not route[k] for k in ("id", "model"))
                or (route["maker"] is not None and not isinstance(route["maker"], str))):
            raise Invalid("invalid-route")
    return routes


def limit_specs(registration, models):
    # Registration scopes name canonical catalog ids, never served spellings.
    if (not isinstance(registration, dict) or not isinstance(registration.get("limits"), dict)
            or not isinstance(registration.get("readerPool"), str) or not registration["readerPool"]):
        raise Invalid("invalid-registration")
    specs = {key: LimitSpec.parse(value) for key, value in sorted(registration["limits"].items())}
    if any(set(spec.models) - models for spec in specs.values()):
        raise Invalid("unknown-model")
    if len({spec.window for spec in specs.values()}) != len(specs):
        raise Invalid("duplicate-window-registration")
    return specs


def capture_observation(capture, reader_pool, now, diagnostic):
    # Isolate capture failures so other captures and reachable routes survive.
    if capture is None:
        diagnostic("missing-capture")
        return None, None
    if not isinstance(capture, dict):
        diagnostic("invalid-capture")
        return None, None
    observed, document = None, None
    try:
        observed = utc(capture["finishedAt"])
        if observed > now:
            observed = None
            raise Invalid("future-observation")
    except Invalid as error:
        diagnostic(str(error))
    except (KeyError, TypeError, ValueError, OverflowError):
        diagnostic("invalid-observation-time")
    try:
        exit_status = capture["exit"]
        if type(exit_status) is not int:
            raise Invalid("invalid-exit-status")
        if exit_status != 0:
            diagnostic("exit-nonzero", exitStatus=exit_status)
        else:
            candidate = envelope(capture)
            if candidate["pool"] != reader_pool:
                raise Invalid("pool-mismatch")
            document = candidate
    except Invalid as error:
        diagnostic(str(error))
    except (KeyError, TypeError, ValueError, OverflowError, RecursionError):
        diagnostic("invalid-json" if "stdout" in capture else "invalid-capture")
    return observed, document


def normalize(snapshot, now):
    """Inspect saved routes and explicitly scoped limits without executing Readers."""
    now = utc(now)
    routes = snapshot_routes(snapshot)
    models = {r["id"] for r in routes}
    diagnostics, pools = [], {}
    for pool, registration in sorted(snapshot["pools"].items()):
        def diagnostic(reason, **details):
            diagnostics.append({"pool": pool, "reason": reason, **details})

        specs = limit_specs(registration, models)
        observed, document = capture_observation(
            snapshot["readers"].get(pool), registration["readerPool"], now, diagnostic
        )
        windows = document["windows"] if document else {}
        observations = [
            window_observation(identifier, spec, windows.get(spec.window), observed, now,
                               lambda reason: diagnostic(reason, limit=identifier))
            for identifier, spec in specs.items()
        ]
        unresolved = len(set(windows) - {spec.window for spec in specs.values()})
        if unresolved:
            diagnostic("unregistered-window", count=unresolved)
        pools[pool] = {"limits": observations, "readerMetadata": metadata(document or {}, diagnostic),
                       "scopeResolved": document is not None and unresolved == 0}
    return {"asOf": now, "capability": "allowance-preview", "diagnostics": diagnostics,
            "pools": pools, "routes": routes, "runtime": snapshot["runtime"]}
