# cspell:ignore behaviour sdoc sgra
"""Hand-written state-field semantics for this repository's `.sdoc` graph.

WHAT THIS IS. Three of the grammar's SingleChoice fields -- DEPTH, STATUS and
AUTHORED_BY -- describe a lifecycle nothing has ever written down. This package
writes them down as `transitions` machines so the claims can be printed,
diagrammed, cross-checked against the grammar and argued with. It is a SPIKE:
the transitions are transcriptions and placeholders, and the questions nobody
has answered travel as `kind="open"` rules rather than being quietly decided.

THE DEC-LAYER-STACK WAIVER. That decision rules SEMANTICS ARE NEVER WRITTEN
DIRECTLY INTO A TOOL -- a rule in the body of a script rather than in an L3
definition that decomposes onto L2 is a layering violation regardless of
whether the rule is right. This package is exactly that, WAIVED BY THE OPERATOR
for the spike ("for the spike the semantics can be written in direct python").
When SLICE-BEHAVIOUR-MODEL lands, `machines/` becomes the fixture the typed Nix
surface must reproduce -- not the thing that ships.

THREE LAYERS, and the split is what makes a new field cheap:

* `declare` -- the vocabulary (State, Transition, Rule, Semantic, `ordered`).
  Stdlib only, no `transitions` import, nothing runs.
* `machines/<field>` -- one module per state field. Pure declaration.
* `engine` -- the only module that imports `transitions`. Builds the machine,
  asks it which states are terminal, computes the diagnostics, renders the
  `sdoc-semantics/1` payload and the mermaid diagram.

Nothing here imports strictdoc and nothing loads the corpus. The grammar
arrives as a `scribe_grammar.parse_sgra` dict, which is read from one file.

WHAT `transitions` CANNOT HOLD, and must not be faked into holding: rules
between two nodes (a supersession needs its Superseded_By target), actors and
authority, ripple, and readiness -- which is a graph query over a node and its
parents, never a value a node carries.
"""

from .declare import RULE_KINDS, Rule, Semantic, State, Transition, ordered, states_of
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
from .registry import SEMANTICS, fields, semantics


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
    "ordered",
    "payload",
    "reachable_states",
    "semantics",
    "states_of",
    "terminal_states",
]
