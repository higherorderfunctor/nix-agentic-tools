"""Normalize saved usage for the offline checks.

A Reader is a command that reports quota. `normalize(snapshot, now)` takes
CPA-configured model routes, pool limits that name Reader windows, and saved
Reader command results. It returns the same routes, allowance records, and safe
reason codes. It reads no clock and runs no commands.
"""
from __future__ import annotations

import math
from typing import Annotated, Any, Callable, Literal, Self

from pydantic import (AwareDatetime, BeforeValidator, BaseModel, ConfigDict, Field,
                    GetPydanticSchema, StrictInt, StrictStr, StringConstraints,
                    TypeAdapter, ValidationError, model_validator)
from pydantic.types import OnErrorOmit
from pydantic_core import core_schema, from_json

Amount = Annotated[float, Field(strict=True, ge=0, allow_inf_nan=False)]
Nonempty = Annotated[str, StringConstraints(strict=True, min_length=1)]
Percent = Annotated[Amount, Field(le=100)]
Positive = Annotated[Amount, Field(gt=0)]
# An offset makes replay independent of the machine's local timezone.
IsoText = Annotated[str, StringConstraints(strict=True, pattern=r"^\d{4}-\d{2}-\d{2}T")]
Timestamp = Annotated[AwareDatetime, BeforeValidator(TypeAdapter(IsoText).validate_python)]
Diagnostic = Callable[..., None]
ENFORCEMENT = dict.fromkeys(("active", "critical", "estimated", "normal", "ok", "warning"), True)


# The one-hour default is an inherited, caller-configurable policy; no cadence rationale is documented. now - finishedAt above it means stale.
def normalize(snapshot: Snapshot | dict, now: str, *,
             max_capture_age_seconds: Amount = 60 * 60) -> Normalized:
    """Turn a snapshot into routes, pool evidence, allowance facts, and diagnostics; see the models below."""
    max_capture_age_seconds = TypeAdapter(Amount).validate_python(max_capture_age_seconds)
    as_of = int(TypeAdapter(Timestamp).validate_python(now).timestamp())
    snapshot = Snapshot.model_validate(snapshot)

    # Callers use these reason codes to explain missing or unusable allowance
    # without exposing Reader payloads.
    diagnostics: list[dict[str, str | int]] = []
    pools: dict[str, PoolEvidence] = {}
    for pool, registration in sorted(snapshot.pools.items()):
        def record_diagnostic(reason: str, **details: str | int) -> None:
            diagnostics.append({"pool": pool, "reason": reason, **details})

        captured_at, payload = read_capture(snapshot.readers.get(pool), registration.readerPool,
                                            as_of, record_diagnostic)
        windows = payload.windows if payload is not None else {}
        observations: list[Observation] = [
            normalize_limit(identifier, spec, windows.get(spec.window), captured_at, as_of, max_capture_age_seconds,
                            lambda reason: record_diagnostic(reason, limit=identifier))
            for identifier, spec in sorted(registration.limits.items())
        ]
        unregistered_count = len(set(windows) - {spec.window for spec in registration.limits.values()})
        if unregistered_count:
            record_diagnostic("unregistered-window", count=unregistered_count)
        pools[pool] = PoolEvidence(limits=observations, scopeResolved=payload is not None and unregistered_count == 0)
    return Normalized(asOf=as_of, diagnostics=diagnostics, pools=pools,
                      routes=snapshot.routes, runtime=snapshot.runtime)


def read_capture(raw: Any, reader_pool: str, as_of: int, diagnostic: Diagnostic) -> tuple[int | None, Envelope | None]:
    """Return capture time and a matching Reader payload, or explain why either is unavailable."""
    if raw is None:
        diagnostic("missing-capture")
        return None, None
    try:
        capture = Capture.model_validate(raw)
    except ValidationError:
        diagnostic("invalid-capture")
        return None, None

    captured_at = int(capture.finishedAt.timestamp()) if capture.finishedAt else None
    if captured_at is None:
        diagnostic("invalid-observation-time")
    elif captured_at > as_of:
        diagnostic("future-observation")
        captured_at = None

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
                return captured_at, None
        try:
            payload = Envelope.model_validate(candidate)
        except ValidationError:
            diagnostic("invalid-envelope")
            return captured_at, None
        if payload.pool == reader_pool:
            return captured_at, payload
        diagnostic("pool-mismatch")
    return captured_at, None


def normalize_limit(identifier: str, spec: LimitSpec, raw: Any, captured_at: int | None, as_of: int,
                    max_capture_age_seconds: Amount, diagnostic: Diagnostic) -> Observation:
    """Return the allowance record that keeps one configured limit visible in the result."""
    result = Observation(id=identifier, capacity=spec.capacity, models=spec.models,
                         role=spec.role, unit=spec.unit, status="missing",
                         observedAt=captured_at, enforced=None, gateOpensAt=None,
                         naturalResetAt=None, readerStatus=None, remaining=None,
                         used=None, windowSeconds=None)
    if raw is None:
        diagnostic("missing-window")
        return result
    try:
        window = Window.model_validate(raw)
    except ValidationError:
        diagnostic("invalid-window")
        result.status = "invalid"
        return result

    invalid = captured_at is None
    if window.remainingPercent is None:
        diagnostic("invalid-quantity")
        invalid = True
    else:
        result.remaining = spec.capacity * (window.remainingPercent / 100)
        result.used = spec.capacity * (window.usedPercent / 100)
    result.windowSeconds = window.windowSeconds
    if window.windowSeconds is None:
        diagnostic("invalid-duration")
        invalid = True

    reset = int(window.resetsAt.timestamp()) if window.resetsAt else None
    idle = result.used == 0 and result.remaining == spec.capacity
    open_gate = spec.role == "gate" and result.remaining is not None and result.remaining > 0
    result.naturalResetAt = reset
    # Reader reset rounding and capture truncation can differ by one second.
    if "resetsAt" not in window.model_fields_set or (reset is None and not (idle or open_gate)) \
            or (reset is not None and captured_at is not None and window.windowSeconds is not None
                and reset - captured_at > window.windowSeconds + 1):
        diagnostic("invalid-reset")
        invalid = True

    if "status" not in window.model_fields_set:
        diagnostic("invalid-status")
        invalid = True
    else:
        result.readerStatus = window.status
        result.enforced = ENFORCEMENT.get(window.status)
        if result.enforced is None:
            diagnostic("unknown-enforcement")

    stale = captured_at is not None and (
        as_of - captured_at > max_capture_age_seconds or (reset is not None and reset <= as_of))
    result.status = "invalid" if invalid else "stale" if stale else "valid"
    if result.status == "valid" and spec.role == "gate" and result.remaining == 0:
        result.gateOpensAt = reset
    return result


class Boundary(BaseModel):
    model_config = ConfigDict(extra="ignore")

    @model_validator(mode="after")
    def restore_omitted_defaults(self) -> Self:
        # OnErrorOmit leaves invalid fields absent; callers consume their defaults.
        for name in set(type(self).model_fields) - self.__dict__.keys():
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
    def unique_windows(self) -> Self:
        if len({spec.window for spec in self.limits.values()}) != len(self.limits):
            raise ValueError("duplicate-window-registration")
        return self


class Route(Boundary):
    model_config = ConfigDict(extra="forbid")
    id: Nonempty
    maker: StrictStr | None
    model: Nonempty


class Snapshot(Boundary):
    """Match each pool's limit registrations to model routes from the CPA configuration.

    A registration names a Reader window and the models it limits. Refuse unknown
    model ids before parsing saved Reader command results, so usage cannot be
    assigned to an undeclared model.
    """

    pools: dict[str, Registration]
    readers: dict[str, Any]
    routes: list[Route]
    runtime: Nonempty

    @model_validator(mode="after")
    def registered_models_exist(self) -> Self:
        route_ids = {route.id for route in self.routes}
        registered = {model for pool in self.pools.values() for spec in pool.limits.values() for model in spec.models}
        if registered - route_ids:
            raise ValueError("unknown-model")
        return self


class Capture(Boundary):
    data: Any = None
    exit: OnErrorOmit[StrictInt] = None
    finishedAt: OnErrorOmit[Timestamp] = None
    # Supplied stdout wins even when invalid, so decoded data cannot mask it.
    stdout: Annotated[StrictStr, GetPydanticSchema(
        lambda source, handler: core_schema.with_default_schema(
            handler(source), default=None, on_error="default"))] = None


class Account(Boundary):
    auth_index: StrictStr | None
    name: StrictStr | None
    plan: StrictStr | None


class Envelope(Boundary):
    account: Account
    pool: Nonempty
    windows: dict[str, Any]


class Window(Boundary):
    remainingPercent: OnErrorOmit[Percent] = None
    resetsAt: OnErrorOmit[Timestamp | None] = None
    status: OnErrorOmit[StrictStr | None] = None
    usedPercent: OnErrorOmit[Percent] = None
    windowSeconds: OnErrorOmit[Positive] = None

    @model_validator(mode="after")
    def consistent_quantities(self) -> Self:
        if (self.remainingPercent is None or self.usedPercent is None
                or not math.isclose(self.remainingPercent + self.usedPercent, 100)):
            self.remainingPercent = self.usedPercent = None
        return self


class Observation(BaseModel):
    capacity: Positive
    enforced: bool | None
    gateOpensAt: int | None
    id: str
    models: list[str]
    naturalResetAt: int | None
    observedAt: int | None
    readerStatus: str | None
    remaining: Amount | None
    role: Literal["gate", "pace"]
    status: Literal["invalid", "missing", "stale", "valid"]
    unit: Literal["percentagePoint", "USD"]
    used: Amount | None
    windowSeconds: Positive | None


class PoolEvidence(BaseModel):
    limits: list[Observation]
    scopeResolved: bool


class Normalized(BaseModel):
    asOf: int
    diagnostics: list[dict[str, str | int]]
    pools: dict[str, PoolEvidence]
    routes: list[Route]
    runtime: str
