# cspell:ignore sdoc
"""STATUS -- a DECISION's standing. NOT a ladder, and that is the point.

DEPTH and AUTHORED_BY are both straight lines, so a spike built only from them
would prove nothing about branching. This one branches: `open` forks to
`accepted` or `rejected`, and only the accepted arm can go on to
`superseded`. It gives the payload two terminal states and an unreachable-state
diagnostic that would actually fire if someone deleted the `reject` edge.

THE ONE RULE THE CORPUS ALREADY ENFORCES BY HAND: never edit an accepted
DECISION's STATEMENT -- set STATUS to superseded, add Superseded_By, and write
a new decision (dev/skills/sdoc/SKILL.md, rule 4). It is written in a skill and
obeyed by convention; transcribing it here is the first time it has been said
in a form something could check.

WHAT IS DELIBERATELY ABSENT. `Superseded_By` must point at the replacing
DECISION, and no state machine can express that -- it is a relation between two
nodes, which is precisely the class of rule `transitions` cannot carry. It is
recorded as an open rule so the gap is visible on the board rather than
implied by silence.
"""

from __future__ import annotations

from ..declare import Rule, Semantic, Transition, states_of

FIELD = "STATUS"

STATES = states_of(
    ("open", "open", "proposed, and nobody has ruled"),
    ("accepted", "accepted", "in force; its statement is now immutable"),
    ("rejected", "rejected", "ruled against -- terminal, and not the same as withdrawn"),
    ("superseded", "superseded", "replaced by a later decision that must be named"),
)

SEMANTIC = Semantic(
    field=FIELD,
    states=STATES,
    transitions=(
        Transition(
            trigger="accept",
            source="open",
            dest="accepted",
            rule_text="a human rules for it; the statement becomes immutable at this moment",
            settled=False,
        ),
        Transition(
            trigger="reject",
            source="open",
            dest="rejected",
            rule_text="a human rules against it; the node stays as the record of the ruling",
            settled=False,
        ),
        Transition(
            trigger="supersede",
            source="accepted",
            dest="superseded",
            rule_text="only an ACCEPTED decision can be superseded; a rejected one was never in force",
            settled=False,
        ),
    ),
    rules=(
        Rule(
            id="STATUS-SUPERSEDE-NEVER-EDIT",
            text=(
                "Never edit an accepted DECISION's STATEMENT. Set STATUS to "
                "superseded, add Superseded_By, and write a new decision "
                "(dev/skills/sdoc/SKILL.md rule 4; DEC-UID-OUTLIVES-TYPE "
                "records four accepted decisions whose statements are frozen)."
            ),
            kind="transcription",
            settled=True,
            cites=("DEC-UID-OUTLIVES-TYPE",),
        ),
        Rule(
            id="STATUS-SUPERSEDE-NEEDS-A-TARGET",
            text=(
                "Reaching superseded without a Superseded_By relation is a "
                "dangling supersession. That is a rule ABOUT TWO NODES, so no "
                "state machine can carry it -- it wants the graph query the "
                "closure verdict already uses."
            ),
            kind="open",
            settled=False,
            cites=("DEC-UID-OUTLIVES-TYPE",),
        ),
        Rule(
            id="STATUS-WITHDRAWN-MISSING-UNDECIDED",
            text=(
                "COMMENTARY's STANDING carries a withdrawn value and STATUS "
                "does not. Whether an open DECISION can be taken back without "
                "being rejected is unruled."
            ),
            kind="open",
            settled=False,
        ),
    ),
    note="Branching on purpose: two terminal states, and one rule no machine can hold.",
)
