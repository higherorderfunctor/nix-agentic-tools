# pyright: strict
"""The suite drives this metering Reader through the same direct and CPA bindings as a fill."""

from collections.abc import Callable, Mapping
from datetime import datetime
from pathlib import Path
import subprocess
import sys
from typing import Literal

from pydantic import HttpUrl, SecretStr, ValidationError

from cliproxyapi.usage.transport import CpaInstance, UnknownBinding
from credential_usage.envelope import (
    Account, AccountedSpend, Binding, Envelope, Observed, ObservedWindow, SlotStates, Unsupported,
)
from credential_usage.transport import DirectHttp, FrozenModel, HttpRequest, RequestFailure, Transport, reader_deadline

VENDOR = HttpUrl("https://reader.example/")
PROXY = HttpUrl("https://proxy.example/")


class Settings(FrozenModel):
    """Choose the private token file and transport from the command environment."""

    CREDENTIAL_FILE: str
    TRANSPORT: Literal["cpa", "direct"]


class Meter(FrozenModel):
    """The meter reports the cost it attributes to this credential and the budget it is held to."""

    budget: float
    cost: float
    currency: str


def main(env: Mapping[str, str], clock: Callable[[], datetime]) -> int:
    """Print the observation at completion or one public reason when the meter cannot be read."""
    try:
        settings = Settings.model_validate(env)
        token = SecretStr(Path(settings.CREDENTIAL_FILE).read_text().strip())
        endpoint = VENDOR if settings.TRANSPORT == "direct" else PROXY
        transport: Transport = DirectHttp(endpoint, token, deadline=reader_deadline(env))
        if settings.TRANSPORT == "cpa":
            binding = CpaInstance(endpoint, transport).bind(VENDOR, pin="sample")
            if isinstance(binding, UnknownBinding):
                raise RequestFailure("missing binding")
            transport = binding
        meter = Meter.model_validate_json(transport.request(HttpRequest(method="GET", url=HttpUrl(f"{VENDOR}spend"))).body)
        used = min(meter.cost, meter.budget) / meter.budget * 100
        plan = subprocess.check_output(["reader-plan"], env=env, text=True).strip()
        result = Envelope(
            schemaVersion=1, account=Account(auth_index=None, name=None, plan=plan),
            binding=Binding(endpoint=endpoint, transport=settings.TRANSPORT), pool="sample", observedAt=clock(),
            windows={"budget": ObservedWindow(state="observed", enforced=None, remainingPercent=100 - used, resetsAt=None,
                                              status=None, usedPercent=used, windowSeconds=2592000)},
            accountedSpend=AccountedSpend(cost=meter.cost, currency=meter.currency, source="meter"), balances=[], bonuses=[],
            slotStates=SlotStates(accountedSpend=Observed(state="observed"), credits=Unsupported(state="unsupported"),
                                  grants=Unsupported(state="unsupported"), resetInventory=Unsupported(state="unsupported")),
        )
    except (OSError, RequestFailure, ValidationError, subprocess.SubprocessError):
        print("usage: observation unavailable", file=sys.stderr)
        return 1
    print(result.model_dump_json())
    return 0
