"""Turn saved Reader command output into allowances and safe reasons for ranking."""

from __future__ import annotations

import datetime as dt
import math
from dataclasses import dataclass
from typing import Annotated, Literal, NamedTuple, Self, cast

from pydantic import (
    AwareDatetime,
    BaseModel,
    BeforeValidator,
    Field,
    JsonValue,
    StrictBool,
    StrictInt,
    StrictStr,
    ValidationError,
    model_validator,
)

from usage.scope import (
    Amount,
    LimitSpec,
    LimitValues,
    Nonempty,
    Positive,
    Registration,
    Route,
)

Percent = Annotated[Amount, Field(le=100)]


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
        capture = read_capture(snapshot.readers.get(name), registration)
        limits = [
            window_observation(identifier, spec, capture, now)
            for identifier, spec in sorted(registration.limits.items())
        ]
        unregistered = len(set(capture.windows) - {spec.window for spec in registration.limits.values()})
        scope_resolved = capture.reason is None and not unregistered
        pools[name] = PoolEvidence(limits=limits, scopeResolved=scope_resolved)
    return Normalized(asOf=now, pools=pools, routes=snapshot.routes)


class CaptureEvidence(NamedTuple):
    """Pass the saved completion time and each validated window to the normalizer."""

    observed_at: int | None
    windows: dict[str, WindowParseResult]
    reason: str | None


def read_capture(raw: object, registration: Registration) -> CaptureEvidence:
    """Read a saved command and validate its single account before using its windows."""
    if raw is None:
        return CaptureEvidence(None, {}, "missing-capture")
    try:
        capture = Capture.model_validate(raw)
    except ValidationError:
        return CaptureEvidence(None, {}, "invalid-envelope")

    observed_at = int(capture.finishedAt.timestamp()) if capture.finishedAt else None
    if capture.exit != 0:
        return CaptureEvidence(observed_at, {}, "exit-nonzero")
    return parse_reader_stdout(capture.stdout, registration, observed_at)


def parse_reader_stdout(
    stdout: str, registration: Registration, observed_at: int | None
) -> CaptureEvidence:
    """Give replay and credential collection only the windows attributable to their registration."""
    try:
        envelope = Envelope.model_validate_json(stdout)
    except ValidationError as error:
        invalid_json = any(
            item["type"] == "json_invalid" for item in error.errors(include_input=False)
        )
        return CaptureEvidence(observed_at, {}, "invalid-json" if invalid_json else "invalid-envelope")
    if envelope.pool != registration.readerPool:
        return CaptureEvidence(observed_at, {}, "pool-mismatch")
    auth_index = envelope.account.auth_index
    if registration.pin is not None and auth_index is not None and registration.pin != auth_index:
        return CaptureEvidence(observed_at, {}, "account-mismatch")
    return CaptureEvidence(observed_at, envelope.windows, None)


def window_observation(
    identifier: str,
    spec: LimitSpec,
    capture: CaptureEvidence,
    now: int,
) -> Observation:
    """Return one configured limit's allowance, preserving proven exhaustion.

    The reason tells the caller why an unusable allowance cannot be ranked, and
    whether the saved capture or this window supplied the failed evidence.
    """
    observation = Observation(
        capacity=spec.capacity,
        id=identifier,
        models=spec.models,
        observedAt=capture.observed_at,
        role=spec.role,
    )
    outcome = capture.windows.get(spec.window)
    if outcome is None:
        return observation.model_copy(update={"reason": capture.reason or "missing-window"})

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
        observation.reason = "missing-reset"
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

    if observation.remaining > 0:
        observation.remaining = None
    return observation


class SnapshotRegistration(Registration):
    """Older saved snapshots identify only the pool, with no credential pin."""

    pin: Nonempty | None = None


class Snapshot(BaseModel):
    """Validate configured pools before reading saved Reader output.

    A registration names the Reader pool and windows that supply one pool's
    limits. Routes are the model ids configured in CPA. A capture is saved
    stdout from one Reader command. Refusing unregistered model ids first keeps
    a bad configuration from being hidden by a failed or misleading capture.
    """

    pools: dict[str, SnapshotRegistration]
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
    status: StrictStr | None
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
            and cast(dict[str, object], raw).get("remainingPercent") == 0
        )
        reason = ", ".join(sorted(failures)) or "window"
        return WindowParseResult(None, proven_zero, f"invalid-window: {reason}")


class Account(BaseModel):
    """Require the three identity fields a Reader supplies even for anonymous usage."""

    auth_index: StrictStr | None
    name: StrictStr | None
    plan: StrictStr | None


class Envelope(BaseModel):
    """Bind independently validated windows to the Reader pool that reported them."""

    account: Account
    balances: list[JsonValue]
    bonuses: list[JsonValue]
    pool: Nonempty
    windows: dict[Nonempty, Annotated[WindowParseResult, BeforeValidator(parse_window)]]


class Capture(BaseModel):
    """Read one saved command result without executing its Reader."""

    exit: StrictInt
    finishedAt: Timestamp | None = None
    stdout: StrictStr


class Observation(LimitValues):
    """Give ranking one configured limit's allowance and validity status."""

    enforced: bool | None = None
    id: str
    naturalResetAt: int | None = None
    observedAt: int | None = Field(
        default=None, exclude_if=lambda timestamp: timestamp is None
    )
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
