"""Collect the packaged manifest's CPA offers with a credential-bound Reader.

A vendor Reader receives the CPA identity, explicit pin and transport policy.
All offers of that credential share its capture, including a binding failure.
"""

from collections.abc import Callable
from dataclasses import dataclass
from enum import Enum

from .cpa import UnknownBinding
from .runner import MissingReader, ReaderCapture
from .scope import Nonempty, Registration, Route
from .transport import FrozenModel, HttpPolicy, RequestFailure


class CredentialReader(Registration):
    """The collector passes the selected command, account and HTTP options to the Reader."""

    command: Nonempty | None
    pin: Nonempty | None
    transport: HttpPolicy


class Offer(Route):
    """Carry CPA's launch identity alongside the runtime that can serve this model."""

    credential: Nonempty | None
    instance: Nonempty | None
    runtime: Nonempty


class CaptureFailure(Enum):
    """An HTTP failure keeps the offer available without exposing a response body."""

    REQUEST = "Reader request failed"


Outcome = ReaderCapture | UnknownBinding | CaptureFailure
ReadCredential = Callable[[str, str, CredentialReader], ReaderCapture | UnknownBinding]


@dataclass(frozen=True)
class RouteCapture:
    """A pacing caller receives every offer alongside its capture or failure."""

    route: Offer
    outcome: Outcome


class CredentialUsage(FrozenModel):
    """Join the manifest's CPA offers to the Reader registered for that instance and credential."""

    readers: dict[str, CredentialReader]
    routes: tuple[Offer, ...]

    def collect(self, read: ReadCredential) -> list[RouteCapture]:
        """Run the bound Reader once per credential and retain offers when binding or reading fails."""
        captures: dict[tuple[str, str], Outcome] = {}
        results: list[RouteCapture] = []
        for route in self.routes:
            instance, credential = route.instance, route.credential
            reader = self.readers.get(f"{instance}/{credential}") if instance is not None and credential is not None else None
            outcome: Outcome = MissingReader.NO_COMMAND
            if reader is not None and reader.command is not None and instance is not None and credential is not None:
                key = (instance, credential)
                if key not in captures:
                    try:
                        captures[key] = read(instance, credential, reader)
                    except RequestFailure:
                        captures[key] = CaptureFailure.REQUEST
                outcome = captures[key]
            results.append(RouteCapture(route, outcome))
        return results


class UsageManifest(FrozenModel):
    """Parse the packaged helper JSON once at entry to credential collection."""

    pacing: CredentialUsage
