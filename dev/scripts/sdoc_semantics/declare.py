# cspell:ignore sdoc
"""Small public records shared by the semantics interpreter and its callers."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


class ModelError(ValueError):
    """The semantics document is malformed or names unknown vocabulary."""


@dataclass(frozen=True)
class FireResult:
    """The all-or-nothing result of one command dispatch."""

    verdict: str
    log: tuple[dict[str, Any], ...]
    reason: str | None = None
    refused_by: str | None = None

    @property
    def taken(self) -> bool:
        return self.verdict == "taken"
