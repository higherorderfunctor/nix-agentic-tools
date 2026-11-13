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
        if not isinstance(result.window, str) or not result.window or not isinstance(result.models, list) or not result.models or any(not isinstance(m, str) or not m for m in result.models):
            raise ValueError("invalid-limit-spec")
        return result


def stdout_document(capture):
    # Decode captured stdout when supplied, refusing malformed JSON safely.
    document = capture.get("data")
    if "stdout" in capture:
        try:
            document = json.loads(capture["stdout"])
        except (TypeError, ValueError):
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
    if any(k not in account or (account[k] is not None and not isinstance(account[k], str)) for k in ("auth_index", "name", "plan")):
        raise Invalid("invalid-account")
    if not isinstance(document.get("pool"), str) or not document["pool"].strip() or not isinstance(document.get("windows"), dict):
        raise Invalid("invalid-envelope")
    return document


def metadata(document, diagnostic):
    # Extras are inspection facts, not wallet balances or redemption rights.
    result = {}
    for field in ("balances", "bonuses"):
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
                if field == "balances":
                    if (item["kind"], item["unit"]) not in (("credits", "credits"), ("extra_usage", "USD")):
                        raise ValueError
                    clean = {"kind": item["kind"], "remaining": number(item["remaining"]), "unit": item["unit"]}
                else:
                    if item["kind"] != "rate_limit_reset" or type(item["count"]) is not int:
                        raise ValueError
                    clean = {"count": number(item["count"]), "kind": "rate_limit_reset"}
                clean["expiresAt"] = None if item["expiresAt"] is None else utc(item["expiresAt"])
                result[field].append(clean)
            except (KeyError, TypeError, ValueError, OverflowError):
                diagnostic("invalid-extras", component=field)
    return result


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
        if reset is None and not (spec.role == "gate" and result["remaining"] is not None and result["remaining"] > 0):
            raise ValueError
        result["naturalResetAt"] = reset
        if reset is not None and observed is not None and result["windowSeconds"] is not None and reset - observed > result["windowSeconds"]:
            raise ValueError
    except (KeyError, TypeError, ValueError, OverflowError):
        diagnostic("invalid-reset")
        invalid = True
    status = window.get("status")
    if "status" not in window or (status is not None and status not in ("estimated", "inactive", "normal", "ok")):
        diagnostic("invalid-status")
        invalid = True
    else:
        result["readerStatus"] = status
        result["enforced"] = True if status in ("estimated", "normal", "ok") else None
        if result["enforced"] is None:
            diagnostic("unknown-enforcement")
    reset = result["naturalResetAt"]
    stale = observed is not None and (now - observed > 3600 or (reset is not None and reset <= now))
    result["status"] = "invalid" if invalid else "stale" if stale else "valid"
    if result["status"] == "valid" and spec.role == "gate" and result["remaining"] == 0:
        result["gateOpensAt"] = reset
    return result


def normalize(snapshot, now):
    """Inspect saved routes and explicitly scoped limits without executing Readers."""
    now = utc(now)
    if not isinstance(snapshot, dict) or not isinstance(snapshot.get("runtime"), str) or not snapshot["runtime"] or not isinstance(snapshot.get("pools"), dict) or not isinstance(snapshot.get("readers"), dict) or not isinstance(snapshot.get("routes"), list):
        raise Invalid("invalid-snapshot")
    routes = snapshot["routes"]
    for route in routes:
        if not isinstance(route, dict) or set(route) != {"id", "maker", "model"} or any(not isinstance(route[k], str) or not route[k] for k in ("id", "model")) or (route["maker"] is not None and not isinstance(route["maker"], str)):
            raise Invalid("invalid-route")
    models = {r["id"] for r in routes}  # limits name canonical catalog ids, not served spellings
    diagnostics, pools = [], {}
    for pool, registration in sorted(snapshot["pools"].items()):
        def diagnostic(reason, **details):
            diagnostics.append({"pool": pool, "reason": reason, **details})

        if not isinstance(registration, dict) or not isinstance(registration.get("limits"), dict) or not isinstance(registration.get("readerPool"), str) or not registration["readerPool"]:
            raise Invalid("invalid-registration")
        specs = {key: LimitSpec.parse(value) for key, value in sorted(registration["limits"].items())}
        if any(set(spec.models) - models for spec in specs.values()):
            raise Invalid("unknown-model")
        windows = {spec.window for spec in specs.values()}
        if len(windows) != len(specs):
            raise Invalid("duplicate-window-registration")
        capture = snapshot["readers"].get(pool)
        observed, document = None, None
        if capture is None:
            diagnostic("missing-capture")
        elif not isinstance(capture, dict):
            diagnostic("invalid-capture")
        else:
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
                    try:
                        payload = stdout_document(capture)
                    except (ValueError, TypeError):
                        payload = None
                    failure = payload.get("diagnostic") if isinstance(payload, dict) else None
                    failure = failure if isinstance(failure, dict) else {}
                    reason = failure.get("reason")
                    reason = reason if reason in ("invalid-json", "refused", "timeout", "unpriced-models") else "exit-nonzero"
                    detail = {"exitStatus": exit_status}
                    if type(failure.get("count")) is int and failure["count"] >= 0:
                        detail["count"] = failure["count"]
                    diagnostic(reason, **detail)
                else:
                    candidate = envelope(capture)
                    if candidate["pool"] != registration["readerPool"]:
                        raise Invalid("pool-mismatch")
                    document = candidate
            except Invalid as error:
                diagnostic(str(error))
            except (KeyError, TypeError, ValueError, OverflowError):
                diagnostic("invalid-json" if "stdout" in capture else "invalid-capture")
        observations = []
        for identifier, spec in specs.items():
            observations.append(window_observation(identifier, spec, document["windows"].get(spec.window) if document else None, observed, now,
                                                   lambda reason: diagnostic(reason, limit=identifier)))
        unresolved = len(set(document["windows"]) - windows) if document else 0
        if unresolved:
            diagnostic("unregistered-window", count=unresolved)
        pools[pool] = {"limits": observations, "readerMetadata": metadata(document or {}, diagnostic),
                       "scopeResolved": document is not None and unresolved == 0}
    return {"asOf": now, "capability": "allowance-preview", "diagnostics": diagnostics,
            "pools": pools, "routes": routes, "runtime": snapshot["runtime"]}
