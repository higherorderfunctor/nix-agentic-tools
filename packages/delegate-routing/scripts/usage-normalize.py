"""Offline Reader capture boundary; amounts retain their declared native units."""

import datetime as dt
import json
import math
from dataclasses import dataclass


def number(value, minimum=0):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value) or value < minimum:
        raise ValueError("invalid-number")
    return value


def utc(value):
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    if not isinstance(value, str):
        raise ValueError("invalid-time")
    try:
        instant = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if instant.utcoffset() != dt.timedelta(0):
            raise ValueError("invalid-time")
        return int(instant.timestamp())
    except (OverflowError, ValueError):
        raise ValueError("invalid-time") from None


@dataclass(frozen=True)
class LimitSpec:
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
    document = capture.get("data")
    if "stdout" in capture:
        try:
            document = json.loads(capture["stdout"])
        except (TypeError, ValueError):
            raise ValueError("invalid-json") from None
    return document


def envelope(capture):
    # Same account/envelope contract as delegate-routing-plan.measure; account
    # fields validate association but never escape into inspection output.
    document = stdout_document(capture)
    if not isinstance(document, dict) or not isinstance(document.get("account"), dict):
        raise ValueError("invalid-envelope")
    for field in ("auth_index", "name", "plan"):
        if field not in document["account"] or (document["account"][field] is not None and not isinstance(document["account"][field], str)):
            raise ValueError("invalid-account")
    if not isinstance(document.get("pool"), str) or not document["pool"].strip() or not isinstance(document.get("windows"), dict):
        raise ValueError("invalid-envelope")
    for field in ("balances", "bonuses"):
        # Absent extras are unknown, not a measured empty inventory.
        if field in document and not isinstance(document[field], list):
            raise ValueError("invalid-extras")
    return document


def window_observation(identifier, spec, window, observed, now):
    result = {
        "id": identifier, "capacity": spec.capacity, "unit": spec.unit,
        "role": spec.role, "models": spec.models, "remaining": None,
        "used": None, "windowSeconds": None, "naturalResetAt": None,
        "enforced": None, "gateOpensAt": None,
        "observedAt": observed, "status": "missing", "readerStatus": None,
    }
    if window is None:
        return result, "missing-window"
    try:
        if not isinstance(window, dict):
            raise ValueError("invalid-window")
        remaining, used = number(window["remainingPercent"]), number(window["usedPercent"])
        seconds = number(window["windowSeconds"])
        if remaining > 100 or used > 100 or not math.isclose(remaining + used, 100) or seconds == 0:
            raise ValueError("invalid-window")
        status = window["status"]
        if status is not None and not isinstance(status, str):
            raise ValueError("invalid-status")
        reset = None if window["resetsAt"] is None else utc(window["resetsAt"])
        if reset is not None and reset - observed > seconds:
            raise ValueError("reset-beyond-window")
        if reset is None and not (spec.role == "gate" and remaining > 0):
            raise ValueError("missing-reset")
        result.update(
            remaining=spec.capacity * remaining / 100, used=spec.capacity * used / 100,
            windowSeconds=seconds, naturalResetAt=reset, readerStatus=status,
            enforced=True if status in {None, "estimated", "normal", "ok"} else None,
            gateOpensAt=reset if spec.role == "gate" and remaining == 0 else None,
            status="stale" if now - observed > 3600 or (reset is not None and reset <= now) else "valid",
        )
        return result, "unknown-enforcement" if result["enforced"] is None else None
    except (KeyError, TypeError, ValueError) as error:
        result["status"] = "invalid"
        # Never echo values or arbitrary exception text from a Reader.
        reason = str(error) if isinstance(error, ValueError) else "invalid-window"
        return result, reason


def normalize(snapshot, now):
    """Normalize registered windows once; explicit IDs replace suffix guessing."""
    now = utc(now)
    if not isinstance(snapshot, dict) or not isinstance(snapshot.get("runtime"), str) or not snapshot["runtime"] or not isinstance(snapshot.get("pools"), dict) or not isinstance(snapshot.get("readers"), dict):
        raise ValueError("invalid-snapshot")
    diagnostics, pools = [], {}

    def diagnostic(pool, reason, **details):
        diagnostics.append({"pool": pool, "reason": reason, **details})

    for pool, registration in sorted(snapshot["pools"].items()):
        if not isinstance(registration, dict) or not isinstance(registration.get("limits"), dict) or not isinstance(registration.get("readerPool"), str):
            raise ValueError("invalid-registration")
        specs = {key: LimitSpec.parse(value) for key, value in sorted(registration["limits"].items())}
        windows = [spec.window for spec in specs.values()]
        if len(windows) != len(set(windows)):
            raise ValueError("duplicate-window-registration")
        capture = snapshot["readers"].get(pool)
        observed, document = None, None
        if capture is None:
            diagnostic(pool, "missing-capture")
        else:
            try:
                observed = utc(capture["finishedAt"])
                if observed > now:
                    raise ValueError("future-observation")
                exit_status = capture["exit"]
                if isinstance(exit_status, bool) or not isinstance(exit_status, int):
                    raise ValueError("invalid-exit-status")
                if exit_status != 0:
                    # Only structured safe codes and numeric detail are carried.
                    try:
                        payload = stdout_document(capture)
                    except ValueError:
                        payload = None
                    failure = payload.get("diagnostic", {}) if isinstance(payload, dict) else {}
                    if not isinstance(failure, dict):
                        failure = {}
                    reason = failure.get("reason")
                    reason = reason if reason in {"invalid-json", "refused", "timeout", "unpriced-models"} else "exit-nonzero"
                    detail = {"exitStatus": exit_status}
                    if isinstance(failure.get("count"), int) and not isinstance(failure["count"], bool) and failure["count"] >= 0:
                        detail["count"] = failure["count"]
                    diagnostic(pool, reason, **detail)
                else:
                    document = envelope(capture)
                    if document["pool"] != registration["readerPool"]:
                        raise ValueError("pool-mismatch")
            except (KeyError, TypeError, ValueError) as error:
                document = None
                diagnostic(pool, str(error) if isinstance(error, ValueError) else "invalid-capture")
        observations = []
        for identifier, spec in specs.items():
            observation, reason = window_observation(identifier, spec, document["windows"].get(spec.window) if document else None, observed, now)
            observations.append(observation)
            if reason:
                diagnostic(pool, reason, limit=identifier)
        if document:
            unregistered = set(document["windows"]) - set(windows)
            if unregistered:
                # Unknown suffixes cannot become pool-wide limits or guessed IDs.
                diagnostic(pool, "unregistered-window", count=len(unregistered))
        pools[pool] = {
            "limits": observations,
            "readerMetadata": {field: document.get(field) if document else None for field in ("balances", "bonuses")},
            # Installed projections do not establish real lots, cap or eligibility.
            "credits": None, "resets": None,
        }
    return {"asOf": now, "capability": "allowance-preview", "diagnostics": diagnostics, "pools": pools, "runtime": snapshot["runtime"]}
