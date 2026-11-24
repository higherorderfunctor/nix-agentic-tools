"""Read usage, profile and prepaid replies on the CLI's bound transport for one usage envelope."""

from collections.abc import Callable
from datetime import datetime
from string import ascii_lowercase, ascii_uppercase
from typing import Annotated, Literal

from pydantic import AliasPath, BeforeValidator, Field, HttpUrl, JsonValue, ValidationError, ValidatorFunctionWrapHandler, WrapValidator

from credential_usage.envelope import (
    Account, Binding, CreditLot, Envelope, Grant, Instant, InvalidWindow, MissingWindow, Name, Observed, ObservedWindow,
    Percent, Quantity, Scope, SlotStates, Unknown, Unsupported, Window,
)
from credential_usage.transport import FrozenModel, HttpRequest, RequestFailure, Transport


VENDOR = HttpUrl("https://api.anthropic.com")
PROFILE_URL = HttpUrl("https://api.anthropic.com/api/oauth/profile")
USAGE_URL = HttpUrl("https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1")
ASCII_LOWER = str.maketrans(ascii_uppercase, ascii_lowercase)


def invalid_as(fallback: object) -> WrapValidator:
    """Keep a malformed field local to its meter so sibling windows can still be observed."""
    def validate(value: object, handler: ValidatorFunctionWrapHandler) -> object:
        try:
            return handler(value)
        except ValueError:
            return fallback
    return WrapValidator(validate)


Used = Annotated[Percent | None, invalid_as(None)]
Reset = Annotated[Instant | None | Literal["invalid"], invalid_as("invalid")]


class VendorResponse(FrozenModel, extra="ignore"):
    """Read known fields strictly as the usage API adds new fields."""


class Meter(VendorResponse):
    """Read each vendor meter independently and preserve only proven remaining capacity."""

    utilization: Used = None
    resets_at: Reset = None

    def window(self, seconds: int, status: str | None) -> Window:
        """Project this meter's share and reset together under its own window id."""
        used, reset = self.utilization, self.resets_at
        if used is None:
            return InvalidWindow(state="invalid", reason="invalid-utilization")
        if reset == "invalid" or (reset is None and used != 0):
            if used == 100:
                return InvalidWindow(state="invalid", reason="invalid-reset", remainingPercent=0)
            return InvalidWindow(state="invalid", reason="invalid-reset")
        return ObservedWindow(
            state="observed", enforced=None, remainingPercent=100 - used, resetsAt=reset,
            status=status, usedPercent=used, windowSeconds=seconds,
        )


ReportedMeter = Annotated[Meter | None, invalid_as(Meter())]


class Limit(Meter):
    """Read the weekly status and the separately metered model from Claude's limits array."""

    kind: Annotated[str | None, invalid_as(None)] = None
    utilization: Used = Field(default=None, alias="percent")
    display_name: Annotated[str | None, Field(pattern=r"^[^:\s][^:]*$"), invalid_as(None)] = Field(
        default=None, validation_alias=AliasPath("scope", "model", "display_name")
    )
    is_active: Annotated[bool | None, invalid_as(None)] = None
    severity: Annotated[str | None, invalid_as(None)] = None


def limit_object_or_empty(value: JsonValue) -> JsonValue:
    """A non-object supplies no kind, name or weekly status."""
    return value if isinstance(value, dict) else {}


def integral_float_as_int(value: JsonValue) -> JsonValue:
    """JSON numbers such as 2.0 still report a whole reset count."""
    return int(value) if isinstance(value, float) and value.is_integer() else value


class VendorGrant(VendorResponse):
    """Read one grant's terms from the primary response for the public inventory."""

    id: Name
    clears: list[str]
    resets_left: Annotated[Quantity, BeforeValidator(integral_float_as_int)]
    effect: str | None = None
    ends_at: Instant | None = None
    gives_back_weekly: bool | None = None
    paused: bool | None = None
    scope: Scope = None
    starts_at: Instant | None = None
    usable_now: bool | None = None
    use_requires_limit: bool | None = None

    def public_grant(self, eligible: bool | None, weekly_reset: datetime | None) -> Grant:
        """Combine account eligibility with the grant's own usability flags."""
        usable = None
        if eligible is False or self.paused is True or self.usable_now is False:
            usable = False
        elif eligible is True and self.paused is False and self.usable_now is True:
            usable = True
        return Grant(
            kind="grant", clears=self.clears, effect=self.effect, eligible=eligible,
            expiresAt=self.ends_at, funding="promotional", givesBackWeekly=self.gives_back_weekly,
            handle=self.id, remaining=self.resets_left, requiresLimit=self.use_requires_limit,
            scope=self.scope, startsAt=self.starts_at, usable=usable, weeklyResetsAt=weekly_reset,
        )


class GrantInventory(VendorResponse):
    """Read eligibility and the shared weekly reset alongside every grant on this account."""

    eligible: bool | None = None
    grants: list[VendorGrant]
    weekly_resets_at: Instant | None = None


class Usage(VendorResponse):
    """Parse the primary reply once, keeping null optional meters distinct from malformed ones."""

    cedar_ember: Annotated[GrantInventory | None, invalid_as(None)] = None
    five_hour: ReportedMeter = None
    seven_day: ReportedMeter = None
    seven_day_opus: ReportedMeter = None
    seven_day_sonnet: ReportedMeter = None
    limits: tuple[Annotated[Limit, BeforeValidator(limit_object_or_empty)], ...] = ()

    def windows(self) -> dict[str, Window]:
        """Publish expected rows even when absent and include each reported optional scope."""
        if not self.model_fields_set.difference({"cedar_ember"}):
            raise RequestFailure("invalid claude usage response")
        weekly_status = next((limit.severity for limit in self.limits if limit.kind == "weekly_all"), None)
        missing = MissingWindow(state="missing", reason="meter-unreported")
        rows: dict[str, Window] = {
            "5h": self.five_hour.window(18000, None) if self.five_hour else missing,
            "7d": self.seven_day.window(604800, weekly_status) if self.seven_day else missing,
        }
        for name, meter in (("opus", self.seven_day_opus), ("sonnet", self.seven_day_sonnet)):
            if meter is not None:
                rows[f"7d:{name}"] = meter.window(604800, None)
        for limit in self.limits:
            # Only named weekly scopes identify a separate window.
            if limit.kind != "weekly_scoped" or not limit.display_name:
                continue
            status = None if limit.is_active is None else "active" if limit.is_active else "inactive"
            window_id = f"7d:{limit.display_name.translate(ASCII_LOWER)}"
            if window_id in rows:
                rows[window_id] = InvalidWindow(state="invalid", reason="conflicting-meter")
            else:
                rows[window_id] = limit.window(604800, status)
        return rows


class Profile(VendorResponse):
    """Only the organization on the bound profile can select the prepaid endpoint."""

    organization_id: Annotated[str, Field(pattern=r"^[A-Za-z0-9-]+$")] = Field(
        validation_alias=AliasPath("organization", "uuid")
    )


class Tranche(VendorResponse):
    """Read the amount and expiry from one USD lot before converting cents to dollars."""

    currency: Literal["USD"]
    expires_at: Instant | None = None
    remaining_amount_minor_units: Annotated[float, Field(ge=0, allow_inf_nan=False)]

    def credit_lot(self, funding: Literal["promotional", "purchased"]) -> CreditLot:
        """Keep each funding source and expiry attached to its own balance."""
        return CreditLot(
            kind="credit", amount=self.remaining_amount_minor_units / 100, expiresAt=self.expires_at,
            funding=funding, scope=None, unit=self.currency, usable=None,
        )


class Prepaid(VendorResponse):
    """Require both tranche arrays so a partial wallet cannot look like a complete balance."""

    promo_tranches: list[Tranche]
    tranches: list[Tranche]


def read_credits(get_body: Callable[[HttpUrl], str]) -> tuple[list[CreditLot], Observed | Unknown]:
    """Fetch the bound account's wallet and distinguish an unknown organization from a failed balance."""
    try:
        profile = Profile.model_validate_json(get_body(PROFILE_URL))
    except (RequestFailure, ValidationError):
        return [], Unknown(state="unknown", reason="prepaid-organization-unknown")
    try:
        url = HttpUrl(f"https://api.anthropic.com/api/oauth/organizations/{profile.organization_id}/prepaid/credits")
        prepaid = Prepaid.model_validate_json(get_body(url))
    except (RequestFailure, ValidationError):
        return [], Unknown(state="unknown", reason="prepaid-unavailable")
    return [
        *(lot.credit_lot("promotional") for lot in prepaid.promo_tranches),
        *(lot.credit_lot("purchased") for lot in prepaid.tranches),
    ], Observed(state="observed")


def read_usage(
    transport: Transport, binding: Binding, account: Account, agent: str, clock: Callable[[], datetime],
) -> Envelope:
    """Read allowance first, then collect optional inventories and stamp the completed observation."""
    headers = {"anthropic-beta": "oauth-2025-04-20", "User-Agent": agent}
    if binding.transport == "cpa":
        headers["Content-Type"] = "application/json"

    def get_body(url: HttpUrl) -> str:
        """Keep each GET on the same credential and send the same vendor headers."""
        return transport.request(HttpRequest(method="GET", url=url, headers=headers)).body

    try:
        body = get_body(USAGE_URL)
    except RequestFailure:
        raise RequestFailure("claude usage request failed") from None
    usage = Usage.model_validate_json(body)
    windows = usage.windows()
    balances, credits = read_credits(get_body)
    inventory = usage.cedar_ember
    unsupported = Unsupported(state="unsupported")
    return Envelope(
        schemaVersion=1, account=account, binding=binding, observedAt=clock(), pool="claude",
        windows=windows, accountedSpend=None, balances=balances,
        bonuses=[
            grant.public_grant(inventory.eligible, inventory.weekly_resets_at)
            for grant in inventory.grants
        ] if inventory else [],
        slotStates=SlotStates(
            accountedSpend=unsupported, credits=credits, resetInventory=unsupported,
            grants=Observed(state="observed") if inventory else Unknown(state="unknown", reason="grants-unavailable"),
        ),
    )
