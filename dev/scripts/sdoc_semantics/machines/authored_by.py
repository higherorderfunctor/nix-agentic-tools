# cspell:ignore sdoc
"""AUTHORED_BY -- the guard on the REVERSE edge, transcribed from an accepted
DECISION.

DEC-AUTHORSHIP-LADDER (accepted) rules this one, so the SHAPE is not up for
grabs the way DEPTH's is: four values, one monotonic ladder, and a value may
rise and never fall. That is why there is no `lower` trigger and no wrap-around
edge -- a ring here would be a laundering path turning a human commitment back
into something a model may freely reverse.

WHAT THE DECISION LEAVES OPEN, and what therefore stays unsettled here: WHO may
raise a value. Its own NOTES say raising to `llm-accepted` is a human act with
no natural place to happen yet, and MECH-RUNTIME-WRITE-GUARD makes the field
the operator's -- `scribe` refuses to generate a flag for it at all. So every
transition below is a legal SHAPE with no actor attached, which is exactly the
hole the L3 model is meant to fill.
"""

from __future__ import annotations

from ..declare import Rule, Semantic, ordered, states_of

FIELD = "AUTHORED_BY"

TRIGGER = "raise"

STATES = states_of(
    ("llm", "llm", "written by a model, not looked at -- free to reverse"),
    ("llm-accepted", "llm accepted", "a human saw it and let it stand -- an undo must surface"),
    ("llm-adopted", "llm adopted", "a human took it on as their own -- a model may not reverse it"),
    ("human", "human", "written by a human -- differs from adopted only in lineage"),
)

SEMANTIC = Semantic(
    field=FIELD,
    states=STATES,
    transitions=ordered(
        STATES,
        TRIGGER,
        rule_text="rises one rung; who is permitted to raise it is undecided",
        settled=False,
    ),
    rules=(
        Rule(
            id="AUTHORED-BY-RISES-ONLY",
            text=(
                "The ladder is one-directional: a value may rise and never "
                "fall, so there is no reachability question and no way to "
                "launder a human commitment back into a free one."
            ),
            kind="transcription",
            settled=True,
            cites=("DEC-AUTHORSHIP-LADDER",),
        ),
        Rule(
            id="AUTHORED-BY-TREATMENT",
            text=(
                "Three classes over four values: llm is FREE to reverse, "
                "llm-accepted is SOFT (an undo has to surface in the closing "
                "report), llm-adopted and human are HARD -- being unable to "
                "meet one is a STOP condition, not a workaround."
            ),
            kind="transcription",
            settled=True,
            cites=("DEC-AUTHORSHIP-LADDER",),
        ),
        Rule(
            id="AUTHORED-BY-WHO-MAY-RAISE-UNDECIDED",
            text=(
                "No actor is attached to any transition. The decision's own "
                "notes say raising to llm-accepted is a human act with no "
                "natural place to happen, and the write guard makes the field "
                "the operator's, so the machine below is a shape with no hand "
                "on it yet."
            ),
            kind="open",
            settled=False,
            cites=("DEC-AUTHORSHIP-LADDER", "MECH-RUNTIME-WRITE-GUARD"),
        ),
    ),
    note="Shape is settled by an accepted DECISION; the actor is not.",
)
