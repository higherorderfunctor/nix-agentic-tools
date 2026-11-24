"""Usage Readers emit one Envelope per binding. Consumers validate its JSON at capture time."""

from datetime import UTC, datetime
from math import isclose
from typing import Annotated, Literal, Self

from pydantic import (
    MISSING,
    AfterValidator,
    AwareDatetime,
    BeforeValidator,
    ConfigDict,
    Field,
    HttpUrl,
    PlainSerializer,
    model_validator,
)

from .transport import FrozenModel


class ContractModel(FrozenModel):
    """Reject extra fields, infinities and NaN throughout the public result."""

    model_config = ConfigDict(extra="forbid", allow_inf_nan=False, field_title_generator=lambda name, _: name)


def aware_instant(value: object) -> datetime:
    """Read an ISO timestamp or a fill's datetime without treating numbers as epochs."""
    if isinstance(value, str):
        try:
            value = datetime.fromisoformat(value)
        except ValueError:
            raise ValueError("invalid ISO timestamp") from None
    if not isinstance(value, datetime) or value.utcoffset() is None:
        raise ValueError("timestamp needs a UTC offset")
    try:
        return value.astimezone(UTC)
    except OverflowError:
        raise ValueError("timestamp falls outside the UTC calendar") from None


def utc_text(value: datetime) -> str:
    """Write a UTC instant with just the fractional digits the capture needs."""
    stamp = value.replace(tzinfo=None).isoformat()
    if value.microsecond:
        stamp = stamp.rstrip("0")
    return stamp + "Z"


Instant = Annotated[
    AwareDatetime, BeforeValidator(aware_instant), PlainSerializer(utc_text, when_used="json")
]
"""Publish UTC instants at microsecond precision. Drop finer digits without rounding."""

Name = Annotated[str, Field(pattern=r"\S")]
Percent = Annotated[float, Field(ge=0, le=100)]
Quantity = Annotated[int, Field(ge=0)]
SlotReason = Literal["grants-unavailable", "prepaid-organization-unknown", "prepaid-unavailable"]
Scope = Literal["account"] | Annotated[list[Name], Field(min_length=1)] | None
WindowId = Annotated[str, Field(pattern=r"^[^:\s]+(:[^:\s][^:]*)?$")]


def public_endpoint(url: HttpUrl) -> HttpUrl:
    """Keep credentials and query parameters out of a binding's published endpoint."""
    if any(part is not None for part in (url.username, url.password, url.query, url.fragment)):
        raise ValueError("expected a public endpoint without user information, query or fragment")
    return url


class Binding(ContractModel):
    """Identify the transport and public endpoint that supplied this observation."""

    endpoint: Annotated[HttpUrl, AfterValidator(public_endpoint)]
    transport: Literal["direct", "cpa"]


class Account(ContractModel):
    """Preserve the Reader's account identity even when some fields are unknown."""

    auth_index: str | None
    name: str | None
    plan: str | None


class ObservedWindow(ContractModel):
    """Publish the measured shares and the vendor's reset and enforcement information."""

    state: Literal["observed"]
    enforced: bool | None
    remainingPercent: Percent
    resetsAt: Instant | None
    status: str | None
    usedPercent: Percent
    windowSeconds: Annotated[float, Field(gt=0)]

    @model_validator(mode="after")
    def complementary_shares(self) -> Self:
        """Keep the Reader and the pacing helper on the same capacity scale."""
        if not isclose(self.usedPercent + self.remainingPercent, 100):
            raise ValueError("usage percentages must total 100")
        return self


class InvalidWindow(ContractModel):
    """Retain a proven zero when other facts about the window failed validation."""

    state: Literal["invalid"]
    reason: Literal["conflicting-meter", "invalid-reset", "invalid-utilization"]
    remainingPercent: Annotated[float, Field(ge=0, le=0)] | MISSING = MISSING


class MissingWindow(ContractModel):
    """Name a window the vendor omitted so consumers can distinguish it from zero."""

    state: Literal["missing"]
    reason: Literal["meter-unreported"]


Window = Annotated[ObservedWindow | InvalidWindow | MissingWindow, Field(discriminator="state")]


class Observed(ContractModel):
    """Mark a successful inventory read, including one that returned no entries."""

    state: Literal["observed"]


class Unknown(ContractModel):
    """Give consumers a reason code when the Reader could not verify a slot."""

    state: Literal["unknown"]
    reason: SlotReason


class Unsupported(ContractModel):
    """Declare that this Reader does not supply a slot."""

    state: Literal["unsupported"]


SlotState = Annotated[Observed | Unknown | Unsupported, Field(discriminator="state")]


class SlotStates(ContractModel):
    """Require a separate declaration for every optional source of usage data."""

    accountedSpend: SlotState
    credits: SlotState
    grants: SlotState
    resetInventory: SlotState


class CreditLot(ContractModel):
    """Keep one wallet lot's value, expiry and reach separate from allowance."""

    kind: Literal["credit"]
    amount: Annotated[float, Field(ge=0)]
    expiresAt: Instant | None
    funding: Name
    scope: Scope
    unit: Name
    usable: bool | None


class Grant(ContractModel):
    """Keep the vendor's grant terms so consumers can decide where it applies."""

    kind: Literal["grant"]
    clears: list[str]
    effect: str | None
    eligible: bool | None
    expiresAt: Instant | None
    funding: Name
    givesBackWeekly: bool | None
    handle: Name
    remaining: Quantity
    requiresLimit: bool | None
    scope: Scope
    startsAt: Instant | None
    usable: bool | None
    weeklyResetsAt: Instant | None


class ResetLot(ContractModel):
    """Identify one lot of resets with its remaining count and expiry."""

    kind: Literal["reset"]
    expiresAt: Instant | None
    handle: Name
    quantity: Quantity


class AccountedSpend(ContractModel):
    """Attribute an observed cost to its source and currency."""

    cost: Annotated[float, Field(ge=0)]
    currency: Name
    source: Name


class Envelope(ContractModel):
    """Publish allowance windows and optional inventory for one account at one instant."""

    schemaVersion: Annotated[int, Field(ge=1, le=1)]
    account: Account
    binding: Binding
    observedAt: Instant
    pool: Name
    windows: Annotated[
        dict[WindowId, Window],
        Field(min_length=1, json_schema_extra={"additionalProperties": False}),
    ]
    accountedSpend: AccountedSpend | None
    balances: list[CreditLot]
    bonuses: list[Annotated[Grant | ResetLot, Field(discriminator="kind")]]
    slotStates: SlotStates

    @model_validator(mode="after")
    def entries_require_observed_slots(self) -> Self:
        """Prevent consumers from using inventory that its own source could not verify."""
        states = self.slotStates
        if self.balances and not isinstance(states.credits, Observed):
            raise ValueError("credit lots require observed credits")
        if self.accountedSpend is not None and not isinstance(states.accountedSpend, Observed):
            raise ValueError("cost requires observed accounted spend")
        for bonus in self.bonuses:
            state = states.grants if isinstance(bonus, Grant) else states.resetInventory
            if not isinstance(state, Observed):
                raise ValueError("bonus requires an observed inventory")
        return self
