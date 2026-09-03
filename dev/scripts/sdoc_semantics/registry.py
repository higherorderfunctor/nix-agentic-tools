# cspell:ignore sdoc
"""SEMANTICS -- which state fields have a lifecycle, and in which order.

ONE TABLE, and the order is presentational: it is the order the CLI prints
machines in and the order the payload's `machines` dict carries, so the two
never disagree about which one an operator sees first. DEPTH leads because it
is the field on six of the eight node types.

It is keyed by `Semantic.field` rather than by a literal, so a field RENAME is
one edit inside the machine module (WORK-DEPTH-RENAME is live).
"""

from __future__ import annotations

from .declare import Semantic
from .machines import authored_by, depth, status

#: Declaration order is presentation order. Not sorted.
_ORDERED: tuple[Semantic, ...] = (
    depth.SEMANTIC,
    status.SEMANTIC,
    authored_by.SEMANTIC,
)

SEMANTICS: dict[str, Semantic] = {
    semantic.field: semantic for semantic in _ORDERED
}


def semantics() -> tuple[Semantic, ...]:
    """Every declared lifecycle, in presentation order."""
    return _ORDERED


def fields() -> tuple[str, ...]:
    return tuple(SEMANTICS)
