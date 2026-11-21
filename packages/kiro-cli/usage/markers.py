"""Share launch identity between the proxy URL producer and capture addon."""

from __future__ import annotations

import base64
import re
from dataclasses import dataclass


USERNAME_PREFIX = "kiro-usage-"
MARKER = re.compile(r"[0-9a-f]{32}")


@dataclass(frozen=True)
class InvocationMarkers:
    """Carry the process and outermost UUID hex strings from launch to capture."""

    invocation: str
    outermost_invocation: str

    def __post_init__(self):
        """Reject invalid marker hex for the launcher and proxy header decoder."""
        if not MARKER.fullmatch(self.invocation):
            raise ValueError("invalid KIRO_USAGE_INVOCATION marker")
        if not MARKER.fullmatch(self.outermost_invocation):
            raise ValueError("invalid KIRO_USAGE_OUTERMOST_INVOCATION marker")

    @property
    def proxy_username(self) -> str:
        """Give the launcher the username for an empty-password proxy URL."""
        username = USERNAME_PREFIX + self.invocation
        if self.invocation != self.outermost_invocation:
            username += "." + self.outermost_invocation
        return username

    @classmethod
    def from_proxy_authorization(cls, authorization: str) -> InvocationMarkers | None:
        """Decode a Basic proxy header into markers for the capture addon."""
        scheme, _, encoded = authorization.partition(" ")
        if scheme.lower() != "basic":
            return None
        try:
            credentials = base64.b64decode(encoded, validate=True).decode("ascii")
            if credentials.startswith(USERNAME_PREFIX) and credentials.endswith(":"):
                invocation, separator, outermost = credentials[len(USERNAME_PREFIX):-1].partition(".")
                return cls(invocation, outermost if separator else invocation)
        except ValueError:
            pass
        return None
