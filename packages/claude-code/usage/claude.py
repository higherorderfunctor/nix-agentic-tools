"""Read Claude's usage response through either transport and publish its allowance windows."""

from collections.abc import Callable
from datetime import datetime
from string import ascii_lowercase, ascii_uppercase
from typing import Annotated, Literal

from pydantic import AliasPath, Field, HttpUrl, OnErrorOmit, ValidatorFunctionWrapHandler, WrapValidator

from credential_usage.envelope import (
    Account, Binding, Envelope, Instant, InvalidWindow, MissingWindow, ObservedWindow,
    Percent, SlotStates, Unknown, Unsupported, Window,
)
from credential_usage.transport import FrozenModel, HttpRequest, RequestFailure, Transport


VENDOR = HttpUrl("https://api.anthropic.com")
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


class Meter(FrozenModel):
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

    kind: str
    utilization: Used = Field(default=None, alias="percent")
    display_name: Annotated[str, Field(pattern=r"^[^:\s][^:]*$")] | None = Field(
        default=None, validation_alias=AliasPath("scope", "model", "display_name")
    )
    is_active: bool | None = None
    severity: str | None = None


class Usage(FrozenModel):
    """Parse the primary reply once, keeping null optional meters distinct from malformed ones."""

    five_hour: ReportedMeter = None
    seven_day: ReportedMeter = None
    seven_day_opus: ReportedMeter = None
    seven_day_sonnet: ReportedMeter = None
    limits: tuple[OnErrorOmit[Limit], ...] = ()

    def windows(self) -> dict[str, Window]:
        """Publish expected rows even when absent and include each reported optional scope."""
        if not self.model_fields_set:
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
            if limit.kind == "weekly_scoped" and limit.display_name:
                status = None if limit.is_active is None else "active" if limit.is_active else "inactive"
                window_id = f"7d:{limit.display_name.translate(ASCII_LOWER)}"
                if window_id in rows:
                    rows[window_id] = InvalidWindow(state="invalid", reason="conflicting-meter")
                else:
                    rows[window_id] = limit.window(604800, status)
        return rows


def read_usage(
    transport: Transport, binding: Binding, account: Account, agent: str, clock: Callable[[], datetime],
) -> Envelope:
    """Fetch the primary allowance and stamp the bound account's envelope after the read."""
    headers = {"anthropic-beta": "oauth-2025-04-20", "User-Agent": agent}
    if binding.transport == "cpa":
        headers["Content-Type"] = "application/json"
    try:
        response = transport.request(HttpRequest(method="GET", url=USAGE_URL, headers=headers))
    except RequestFailure:
        raise RequestFailure("claude usage request failed") from None
    windows = Usage.model_validate_json(response.body).windows()
    unsupported = Unsupported(state="unsupported")
    return Envelope(
        schemaVersion=1, account=account, binding=binding, observedAt=clock(), pool="claude",
        windows=windows, accountedSpend=None, balances=[], bonuses=[],
        slotStates=SlotStates(
            accountedSpend=unsupported, credits=Unknown(state="unknown", reason="prepaid-unavailable"),
            grants=Unknown(state="unknown", reason="grants-unavailable"), resetInventory=unsupported,
        ),
    )
