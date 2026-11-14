"""Normalize saved Reader captures for the owner's offline boundary tests.

Pydantic parses each independent component; typed observations retain allowance
when timing or optional metadata fails. No Reader or capture command is run.
"""

import math
from typing import Annotated, Any, Literal

from pydantic import (
    AwareDatetime, BaseModel, BeforeValidator, ConfigDict, Field, PrivateAttr,
    StrictInt, StrictStr, StringConstraints, TypeAdapter, ValidationError, model_validator,
)
from pydantic_core import from_json
from pydantic.types import OnErrorOmit

Nonempty = Annotated[str, StringConstraints(strict=True, min_length=1)]
Amount = Annotated[float, Field(strict=True, ge=0, allow_inf_nan=False)]
Positive = Annotated[Amount, Field(gt=0)]
Percent = Annotated[Amount, Field(le=100)]
IsoText = Annotated[str, StringConstraints(strict=True, pattern=r"^\d{4}-\d{2}-\d{2}T")]
Timestamp = Annotated[AwareDatetime, BeforeValidator(TypeAdapter(IsoText).validate_python)]


class Boundary(BaseModel):
    model_config = ConfigDict(extra="ignore")
    _invalid: set[str] = PrivateAttr(default_factory=set)

    @model_validator(mode="after")
    def restore_omitted_defaults(self):
        # OnErrorOmit isolates component failures; retain their names for diagnostics.
        self._invalid = set(type(self).model_fields) - self.__dict__.keys()
        for name in self._invalid:
            object.__setattr__(self, name, type(self).model_fields[name].default)
        return self


class LimitSpec(Boundary):
    model_config = ConfigDict(extra="forbid")
    capacity: Positive
    models: Annotated[list[Nonempty], Field(min_length=1)]
    role: Literal["gate", "pace"]
    unit: Literal["percentagePoint", "USD"]
    window: Nonempty


class Registration(Boundary):
    limits: dict[str, LimitSpec]
    readerPool: Nonempty

    @model_validator(mode="after")
    def unique_windows(self):
        if len({spec.window for spec in self.limits.values()}) != len(self.limits):
            raise ValueError("duplicate-window-registration")
        return self


class Route(Boundary):
    model_config = ConfigDict(extra="forbid")
    id: Nonempty
    maker: StrictStr | None
    model: Nonempty


class Snapshot(Boundary):
    pools: dict[str, Registration]
    # Capture failures belong to one pool, so each payload is parsed separately.
    readers: dict[str, Any]
    routes: list[Route]
    runtime: Nonempty

    @model_validator(mode="after")
    def registered_models_exist(self):
        models = {route.id for route in self.routes}
        if any(set(spec.models) - models for pool in self.pools.values() for spec in pool.limits.values()):
            raise ValueError("unknown-model")
        return self


class Account(Boundary):
    auth_index: StrictStr | None
    name: StrictStr | None
    plan: StrictStr | None


class Window(Boundary):
    remainingPercent: OnErrorOmit[Percent] = None
    resetsAt: OnErrorOmit[Timestamp | None] = None
    status: OnErrorOmit[StrictStr | None] = None
    usedPercent: OnErrorOmit[Percent] = None
    windowSeconds: OnErrorOmit[Positive] = None

    @model_validator(mode="after")
    def consistent_quantities(self):
        if (self.remainingPercent is None or self.usedPercent is None
                or not math.isclose(self.remainingPercent + self.usedPercent, 100)):
            self.remainingPercent = self.usedPercent = None
        return self


class Balance(Boundary):
    expiresAt: Timestamp | None
    kind: Literal["credits", "extra_usage"]
    remaining: Amount
    unit: Literal["credits", "USD"]

    @model_validator(mode="after")
    def kind_matches_unit(self):
        if self.unit != {"credits": "credits", "extra_usage": "USD"}[self.kind]:
            raise ValueError("balance-unit")
        return self


class Bonus(Boundary):
    count: Annotated[int, Field(strict=True, ge=0)]
    expiresAt: Timestamp | None
    kind: Literal["promo_credits", "rate_limit_reset"]


class Envelope(Boundary):
    account: Account
    balances: OnErrorOmit[list[Any]] = None
    bonuses: OnErrorOmit[list[Any]] = None
    pool: Annotated[str, StringConstraints(strict=True, strip_whitespace=True, min_length=1)]
    windows: dict[str, Any]


class Capture(Boundary):
    # Payload parsing follows exit status; failed commands need no usable stdout.
    data: Any = None
    exit: OnErrorOmit[StrictInt] = None
    finishedAt: OnErrorOmit[Timestamp] = None
    stdout: Any = None


def metadata(document: Envelope | None, diagnostic):
    result = {}
    for field, model in (("balances", Balance), ("bonuses", Bonus)):
        items = getattr(document, field) if document else None
        result[field] = None if items is None else []
        if document and field not in document.model_fields_set and field not in document._invalid:
            continue
        if document and items is None:
            diagnostic("invalid-extras", component=field)
        for item in items or []:
            try:
                clean = model.model_validate(item).model_dump()
                clean["expiresAt"] = int(clean["expiresAt"].timestamp()) if clean["expiresAt"] else None
                result[field].append(clean)
            except ValidationError:
                diagnostic("invalid-extras", component=field)
    return result


ENFORCEMENT = dict.fromkeys(("active", "critical", "estimated", "normal", "ok", "warning"), True)


def window_observation(identifier: str, spec: LimitSpec, raw: Any, observed: int | None, now: int, diagnostic):
    result = dict(id=identifier, capacity=spec.capacity, unit=spec.unit,
                  role=spec.role, models=spec.models, remaining=None, used=None,
                  windowSeconds=None, naturalResetAt=None, enforced=None,
                  gateOpensAt=None, observedAt=observed, status="missing", readerStatus=None)
    if raw is None:
        diagnostic("missing-window")
        return result
    try:
        window = Window.model_validate(raw)
    except ValidationError:
        diagnostic("invalid-window")
        result["status"] = "invalid"
        return result
    invalid = observed is None
    if window.remainingPercent is None:
        diagnostic("invalid-quantity")
        invalid = True
    else:
        result.update(remaining=spec.capacity * (window.remainingPercent / 100),
                      used=spec.capacity * (window.usedPercent / 100))
    result["windowSeconds"] = window.windowSeconds
    if window.windowSeconds is None:
        diagnostic("invalid-duration")
        invalid = True
    reset = int(window.resetsAt.timestamp()) if window.resetsAt else None
    idle = result["used"] == 0 and result["remaining"] == spec.capacity
    open_gate = spec.role == "gate" and result["remaining"] is not None and result["remaining"] > 0
    result["naturalResetAt"] = reset
    # Reader reset rounding and capture truncation can differ by one second.
    if ("resetsAt" not in window.model_fields_set or (reset is None and not (idle or open_gate))
            or (reset is not None and observed is not None and window.windowSeconds is not None
                and reset - observed > window.windowSeconds + 1)):
        diagnostic("invalid-reset")
        invalid = True
    if "status" not in window.model_fields_set:
        diagnostic("invalid-status")
        invalid = True
    else:
        result["readerStatus"] = window.status
        result["enforced"] = ENFORCEMENT.get(window.status)
        if result["enforced"] is None:
            diagnostic("unknown-enforcement")
    stale = observed is not None and (now - observed > 3600 or (reset is not None and reset <= now))
    result["status"] = "invalid" if invalid else "stale" if stale else "valid"
    if result["status"] == "valid" and spec.role == "gate" and result["remaining"] == 0:
        result["gateOpensAt"] = reset
    return result


def capture_observation(raw: Any, reader_pool: str, now: int, diagnostic):
    if raw is None:
        diagnostic("missing-capture")
        return None, None
    try:
        capture = Capture.model_validate(raw)
    except ValidationError:
        diagnostic("invalid-capture")
        return None, None
    observed = int(capture.finishedAt.timestamp()) if capture.finishedAt else None
    if observed is None:
        diagnostic("invalid-observation-time")
    elif observed > now:
        diagnostic("future-observation")
        observed = None
    if capture.exit is None:
        diagnostic("invalid-exit-status")
    elif capture.exit != 0:
        diagnostic("exit-nonzero", exitStatus=capture.exit)
    else:
        candidate = capture.data
        if "stdout" in capture.model_fields_set:
            try:
                candidate = from_json(capture.stdout)
            except (TypeError, ValueError):
                diagnostic("invalid-json")
                return observed, None
        try:
            document = Envelope.model_validate(candidate)
        except ValidationError:
            diagnostic("invalid-envelope")
            return observed, None
        if document.pool == reader_pool:
            return observed, document
        diagnostic("pool-mismatch")
    return observed, None


def normalize(snapshot, now):
    """Return deterministic allowance facts using an explicit ISO 8601 clock."""
    now = int(TypeAdapter(Timestamp).validate_python(now).timestamp())
    snapshot = Snapshot.model_validate(snapshot)
    diagnostics, pools = [], {}
    for pool, registration in sorted(snapshot.pools.items()):
        def diagnostic(reason, **details):
            diagnostics.append({"pool": pool, "reason": reason, **details})

        observed, document = capture_observation(snapshot.readers.get(pool), registration.readerPool, now, diagnostic)
        windows = document.windows if document else {}
        observations = [
            window_observation(identifier, spec, windows.get(spec.window), observed, now,
                               lambda reason: diagnostic(reason, limit=identifier))
            for identifier, spec in sorted(registration.limits.items())
        ]
        unresolved = len(set(windows) - {spec.window for spec in registration.limits.values()})
        if unresolved:
            diagnostic("unregistered-window", count=unresolved)
        pools[pool] = {"limits": observations, "readerMetadata": metadata(document, diagnostic),
                       "scopeResolved": document is not None and unresolved == 0}
    return {"asOf": now, "capability": "allowance-preview", "diagnostics": diagnostics,
            "pools": pools, "routes": [route.model_dump() for route in snapshot.routes], "runtime": snapshot.runtime}
