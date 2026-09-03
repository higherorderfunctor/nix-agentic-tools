# cspell:ignore sdoc
"""DEPTH -- how finished a node's thinking is. THE SPIKE'S TEST SEMANTIC.

WHAT IS CLAIMED HERE, AND HOW LITTLE OF IT IS SETTLED. The six values and
their order are TRANSCRIBED from `docs/sdoc/grammar.sgra`; everything else on
this page is a placeholder the operator is expected to tear up. It is
deliberately the dullest possible reading -- one trigger, forward one rung at
a time, no gates, no conditions -- because the point of the spike is to give
the shaping a shape to push against, not to settle it in advance.

THREE QUESTIONS ARE OPEN AND CARRIED AS `kind="open"` RULES rather than being
answered by the transition table:

  * may DEPTH regress? A node whose design is invalidated plausibly falls back
    to `needs-design`, and this ladder cannot express that.
  * do `implemented` and `verified` belong to DEPTH at all? They describe the
    CODE, not the thinking, and readiness is explicitly not a state field.
  * is one machine per field right, or one per (type, field)? A REQUIREMENT's
    `needs-spike` and a WORK's may not be the same rung.

READINESS IS NOT MODELLED, and must not be added here. It is a graph query
over a node and its parents, not a value a node carries -- see
`docs/sdoc/status.py`, whose closure verdict no state machine can express.
"""

from __future__ import annotations

from ..declare import Rule, Semantic, ordered, states_of

#: The field NAME is data. WORK-DEPTH-RENAME is live, so this is the one place
#: the word appears and every consumer keys off `Semantic.field`.
FIELD = "DEPTH"

TRIGGER = "advance"

STATES = states_of(
    ("sketch", "sketch", "a shape, not yet a design"),
    ("needs-design", "needs design", "the shape is agreed; the design is not"),
    ("needs-spike", "needs spike", "the design turns on something unmeasured"),
    ("interface-settled", "interface settled", "the seam is fixed; the body is not"),
    ("implemented", "implemented", "it exists"),
    ("verified", "verified", "something other than its author has checked it"),
)

SEMANTIC = Semantic(
    field=FIELD,
    states=STATES,
    transitions=ordered(
        STATES,
        TRIGGER,
        rule_text="one rung at a time, forwards, with nothing gating the move",
        settled=False,
    ),
    rules=(
        Rule(
            id="DEPTH-ORDERED",
            text=(
                "The six values are a LADDER in the order the grammar declares "
                "them, and the spike reads that order as the only legal path: "
                "one trigger, adjacent rungs, no skipping."
            ),
            kind="transcription",
            settled=False,
            cites=("SLICE-GRAMMAR-FROM-NIX",),
        ),
        Rule(
            id="DEPTH-REGRESSION-UNDECIDED",
            text=(
                "May DEPTH fall? A design invalidated by a spike arguably "
                "returns to needs-design, but a falling DEPTH also erases the "
                "record that it once stood higher. Nobody has ruled."
            ),
            kind="open",
            settled=False,
        ),
        Rule(
            id="DEPTH-RUNGS-UNDECIDED",
            text=(
                "Do implemented and verified belong to DEPTH? They describe "
                "the artifact rather than the thinking, and a node can be "
                "interface-settled forever without either being false."
            ),
            kind="open",
            settled=False,
        ),
        Rule(
            id="DEPTH-SHARED-MACHINE-UNDECIDED",
            text=(
                "One machine per FIELD is the cheapest shape and is what the "
                "spike builds: the six types carrying DEPTH share this "
                "lifecycle exactly. The alternative is one machine per (type, "
                "field), which lets a REQUIREMENT and a WORK disagree about "
                "what a rung means, at the cost of six tables to keep aligned."
            ),
            kind="open",
            settled=False,
        ),
    ),
    note="Transcribed for the spike. Every transition is unsettled by design.",
)
