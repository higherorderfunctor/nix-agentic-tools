# pyright: strict
"""The suite drives this two-request Reader through the same direct and CPA bindings as a fill."""

from collections.abc import Callable, Mapping
from datetime import datetime
from pathlib import Path
import subprocess
import sys
from typing import Literal

from pydantic import HttpUrl, SecretStr, TypeAdapter, ValidationError

from cliproxyapi.usage.transport import CpaInstance, UnknownBinding
from credential_usage.envelope import (
    Account, Binding, CreditLot, Envelope, Observed, ObservedWindow, SlotStates, Unknown, Unsupported,
)
from credential_usage.transport import DirectHttp, FrozenModel, HttpRequest, RequestFailure, Transport, reader_deadline


class Settings(FrozenModel):
    """Choose the private file and transport from the command environment."""
    CREDENTIAL_FILE: str
    TRANSPORT: Literal["cpa", "direct"]


class Credential(FrozenModel):
    """Only the binding reads this credential file."""
    token: SecretStr


class Allowance(FrozenModel):
    """The required vendor reply reports the used share of the window."""
    used: float


VENDOR = HttpUrl("https://reader.example/")
PROXY = HttpUrl("https://proxy.example/")


def main(env: Mapping[str, str], clock: Callable[[], datetime]) -> int:
    """Print the observation at completion or one public reason when the required read fails."""
    try:
        settings = Settings.model_validate(env)
        login = Credential.model_validate_json(Path(settings.CREDENTIAL_FILE).read_bytes())
        endpoint = VENDOR if settings.TRANSPORT == "direct" else PROXY
        transport: Transport = DirectHttp(endpoint, login.token, deadline=reader_deadline(env))
        if settings.TRANSPORT == "cpa":
            binding = CpaInstance(endpoint, transport).bind(VENDOR, pin="sample")
            if isinstance(binding, UnknownBinding):
                raise RequestFailure("missing binding")
            transport = binding
        response = transport.request(HttpRequest(method="GET", url=HttpUrl(f"{VENDOR}allowance"), headers={"Accept": "application/json"}))
        usage = Allowance.model_validate_json(response.body)
        credits: Observed | Unknown = Observed(state="observed")
        balances: list[CreditLot] = []
        try:
            wallet = transport.request(HttpRequest(method="GET", url=HttpUrl(f"{VENDOR}credits")))
            balances = TypeAdapter(list[CreditLot]).validate_json(wallet.body)
        except (RequestFailure, ValidationError):
            credits = Unknown(state="unknown", reason="prepaid-unavailable")
        unsupported = Unsupported(state="unsupported")
        plan = subprocess.check_output(["reader-plan"], env=env, text=True).strip()
        result = Envelope(
            schemaVersion=1, account=Account(auth_index=None, name=None, plan=plan),
            binding=Binding(endpoint=endpoint, transport=settings.TRANSPORT), pool="sample", observedAt=clock(),
            windows={"1h": ObservedWindow(state="observed", enforced=True, remainingPercent=100 - usage.used,
                                          resetsAt=None, status=None, usedPercent=usage.used, windowSeconds=3600)},
            accountedSpend=None, balances=balances, bonuses=[],
            slotStates=SlotStates(accountedSpend=unsupported, credits=credits, grants=unsupported, resetInventory=unsupported),
        )
    except (OSError, RequestFailure, ValidationError, subprocess.SubprocessError):
        print("usage: observation unavailable", file=sys.stderr)
        return 1
    print(result.model_dump_json())
    return 0
