"""Turn saved Reader command output into allowances and safe reasons for ranking."""

from __future__ import annotations

import datetime as dt
import math
from dataclasses import dataclass
from typing import Annotated, Literal, Self

from pydantic import (
    AwareDatetime,
    BaseModel,
    BeforeValidator,
    Field,
    StrictBool,
    StrictInt,
    StrictStr,
    StringConstraints,
    ValidationError,
    model_validator,
)


Amount = Annotated[float, Field(strict=True, ge=0, allow_inf_nan=False)]
Nonempty = Annotated[StrictStr, StringConstraints(min_length=1)]
Percent = Annotated[Amount, Field(le=100)]
Positive = Annotated[Amount, Field(gt=0)]


def parse_iso_timestamp(raw: object) -> dt.datetime:
    """Accept the timestamp shape Readers produce: ISO 8601 text with an offset."""
    if not isinstance(raw, str):
        raise ValueError("timestamp-requires-iso-text")
    return dt.datetime.fromisoformat(raw)


Timestamp = Annotated[AwareDatetime, BeforeValidator(parse_iso_timestamp)]


def normalize(snapshot: Snapshot, now: int) -> Normalized:
    """Keep every configured limit and explain allowance the ranking cannot use."""
    pools: dict[str, PoolEvidence] = {}
    for name, registration in sorted(snapshot.pools.items()):
        windows, capture_reason = read_capture(snapshot.readers.get(name), registration.readerPool)
        limits = [
            window_observation(identifier, spec, windows.get(spec.window), capture_reason, now)
            for identifier, spec in sorted(registration.limits.items())
        ]
        unregistered = len(set(windows) - {spec.window for spec in registration.limits.values()})
        scope_resolved = capture_reason is None and not unregistered
        pools[name] = PoolEvidence(limits=limits, scopeResolved=scope_resolved)
    return Normalized(asOf=now, pools=pools, routes=snapshot.routes)


def read_capture(raw: object, reader_pool: str) -> tuple[dict[str, WindowParseResult], str | None]:
    """Return matching Reader windows, or the reason every pool limit is unusable."""
    if raw is None:
        return {}, "missing-capture"
    try:
        capture = Capture.model_validate(raw)
        if capture.exit != 0:
            return {}, "exit-nonzero"
        payload = Envelope.model_validate_json(capture.stdout)
    except ValidationError as error:
        failures = error.errors(include_url=False)
        json_error = any(item["type"].startswith("json_invalid") for item in failures)
        return {}, "invalid-json" if json_error else "invalid-envelope"
    if payload.pool != reader_pool:
        return {}, "pool-mismatch"
    return {key: parse_window(value) for key, value in payload.windows.items()}, None


def window_observation(
    identifier: str,
    spec: LimitSpec,
    outcome: WindowParseResult | None,
    capture_reason: str | None,
    now: int,
) -> Observation:
    """Return one configured limit's allowance, preserving proven exhaustion.

    The reason tells the caller why an unusable allowance cannot be ranked, and
    whether the saved capture or this window supplied the failed evidence.
    """
    observation = Observation(id=identifier, **spec.model_dump(exclude={"window"}))
    if outcome is None:
        return observation.model_copy(update={"reason": capture_reason or "missing-window"})

    if outcome.window is None:
        observation.status = "invalid"
        observation.reason = outcome.invalid_reason
        if outcome.proven_zero:
            observation.remaining = 0
        return observation

    window = outcome.window
    observation.remaining = spec.capacity * (window.remainingPercent / 100)
    observation.windowSeconds = window.windowSeconds
    observation.enforced = window.enforced
    observation.naturalResetAt = int(window.resetsAt.timestamp()) if window.resetsAt else None
    idle = window.usedPercent == 0 and window.remainingPercent == 100
    open_gate = spec.role == "gate" and window.remainingPercent > 0
    if observation.naturalResetAt is None and not idle and not open_gate:
        observation.status = "invalid"
        observation.reason = "missing-reset: resetsAt"
    elif observation.naturalResetAt is not None and observation.naturalResetAt <= now and not idle:
        observation.status = "stale"
        observation.reason = "expired-reset"
    else:
        observation.status = "valid"
        if window.enforced is None:
            observation.reason = "enforced-unknown"
        elif window.enforced:
            observation.reason = None
        else:
            observation.reason = "not-enforced"
        return observation

    if observation.remaining is not None and observation.remaining > 0:
        observation.remaining = None
    return observation


class LimitValues(BaseModel):
    """Carry the capacity, routes, and role shared by input and output limits."""

    capacity: Positive
    models: Annotated[list[Nonempty], Field(min_length=1)]
    role: Literal["gate", "pace"]


class LimitSpec(LimitValues, extra="forbid"):
    """Bind a Reader window to one configured limit."""

    window: Nonempty


class Registration(BaseModel):
    """Name the Reader pool and exact windows a configuration registers."""

    limits: dict[str, LimitSpec]
    readerPool: Nonempty

    @model_validator(mode="after")
    def unique_windows(self) -> Self:
        """Refuse two limits that claim the same Reader window."""
        windows = {spec.window for spec in self.limits.values()}
        if len(windows) != len(self.limits):
            raise ValueError("duplicate-window-registration")
        return self


class Route(BaseModel):
    """Carry one configured model identity into ranking."""

    id: Nonempty
    maker: StrictStr | None
    model: Nonempty


class Snapshot(BaseModel):
    """Validate configured pools before reading saved Reader output.

    A registration names the Reader pool and windows that supply one pool's
    limits. Routes are the model ids configured in CPA. A capture is saved
    stdout from one Reader command. Refusing unregistered model ids first keeps
    a bad configuration from being hidden by a failed or misleading capture.
    """

    pools: dict[str, Registration]
    readers: dict[str, object]
    routes: list[Route]

    @model_validator(mode="after")
    def registered_models_exist(self) -> Self:
        """Refuse limits for models absent from the configured routes."""
        registered = {
            model
            for pool in self.pools.values()
            for spec in pool.limits.values()
            for model in spec.models
        }
        if registered - {route.id for route in self.routes}:
            raise ValueError("unknown-model")
        return self


class Window(BaseModel):
    """Validate one complete allowance window."""

    enforced: StrictBool | None = None
    remainingPercent: Percent
    resetsAt: Timestamp | None
    usedPercent: Percent
    windowSeconds: Positive

    @model_validator(mode="after")
    def quantities_sum_to_full_capacity(self) -> Self:
        """Keep used and remaining percentages on one full capacity scale."""
        if not math.isclose(self.remainingPercent + self.usedPercent, 100):
            raise ValueError("inconsistent-quantities")
        return self


@dataclass(frozen=True)
class WindowParseResult:
    """Carry one Reader window after boundary validation."""

    window: Window | None
    proven_zero: bool
    invalid_reason: str | None


def parse_window(raw: object) -> WindowParseResult:
    """Validate a window once, preserving only a proven remaining value of zero."""
    try:
        window = Window.model_validate(raw)
        return WindowParseResult(window, window.remainingPercent == 0, None)
    except ValidationError as error:
        failures = {str(item["loc"][0]) for item in error.errors(include_url=False) if item["loc"]}
        proven_zero = (
            isinstance(raw, dict)
            and "remainingPercent" not in failures
            and raw.get("remainingPercent") == 0
        )
        reason = ", ".join(sorted(failures)) or "window"
        return WindowParseResult(None, proven_zero, f"invalid-window: {reason}")


class Envelope(BaseModel):
    """Bind independently validated windows to the Reader pool that reported them."""

    pool: Nonempty
    windows: dict[Nonempty, object]


class Capture(BaseModel):
    """Read one saved command result without executing its Reader."""

    exit: StrictInt
    stdout: StrictStr


class Observation(LimitValues):
    """Give ranking one configured limit's allowance and validity status."""

    enforced: bool | None = None
    id: str
    naturalResetAt: int | None = None
    reason: str | None = None
    remaining: Amount | None = None
    status: Literal["invalid", "missing", "stale", "valid"] = "missing"
    windowSeconds: Positive | None = None


class PoolEvidence(BaseModel):
    """Keep configured limits together with their scope completeness."""

    limits: list[Observation]
    scopeResolved: bool


class Normalized(BaseModel):
    """Return the replay clock, routes, and allowances used by ranking."""

    asOf: int
    pools: dict[str, PoolEvidence]
    routes: list[Route]
