# cspell:ignore behaviour sdoc sgra
"""Data-defined state-field semantics for this repository's `.sdoc` graph.

WHAT THIS IS. Three of the grammar's SingleChoice fields -- DEPTH, STATUS and
AUTHORED_BY -- describe a lifecycle nothing has ever written down. This package
writes them in ``model.json`` so the claims can be printed, diagrammed,
cross-checked against the grammar and argued with. The transitions are
transcriptions and placeholders, and unanswered questions travel as open rules.

``declare`` temporarily adapts the document to the spike engine. The next work
item replaces that engine with the standard-library interpreter over the same
document.

Nothing here imports strictdoc and nothing loads the corpus. The grammar
arrives as a `scribe_grammar.parse_sgra` dict, which is read from one file.

WHAT `transitions` CANNOT HOLD, and must not be faked into holding: rules
between two nodes (a supersession needs its Superseded_By target), actors and
authority, ripple, and readiness -- which is a graph query over a node and its
parents, never a value a node carries.
"""

from pathlib import Path

from .declare import RULE_KINDS, Rule, Semantic, State, Transition, load_semantics
from .engine import (
    SCHEMA,
    applies_to,
    build_machine,
    diagnostics,
    machine_payload,
    markup_of,
    mermaid,
    payload,
    reachable_states,
    terminal_states,
)

_MODEL_PATH = Path(__file__).with_name("model.json")
_ORDERED = load_semantics(_MODEL_PATH)
SEMANTICS = {semantic.field: semantic for semantic in _ORDERED}


def semantics() -> tuple[Semantic, ...]:
    """Every data-defined lifecycle, in presentation order."""
    return _ORDERED


def fields() -> tuple[str, ...]:
    return tuple(SEMANTICS)


def build_payload(grammar) -> dict:
    """THE ONE ENTRY POINT a consumer needs: a parsed grammar in, the
    `sdoc-semantics/1` payload for every registered lifecycle out.

        from scribe_grammar import parse_sgra
        import sdoc_semantics
        snapshot["semantics"] = sdoc_semantics.build_payload(
            parse_sgra(root / "docs/sdoc/grammar.sgra")
        )

    The board calls this; so does `scribe semantics`; so does the CLI. Nothing
    downstream should assemble the payload from `payload(semantics(), ...)`
    itself -- that spelling is the plumbing, this is the seam.
    """
    return payload(semantics(), grammar)

__all__ = [
    "RULE_KINDS",
    "SCHEMA",
    "SEMANTICS",
    "Rule",
    "Semantic",
    "State",
    "Transition",
    "applies_to",
    "build_machine",
    "build_payload",
    "diagnostics",
    "fields",
    "machine_payload",
    "markup_of",
    "mermaid",
    "payload",
    "reachable_states",
    "semantics",
    "terminal_states",
]
