# cspell:ignore behaviour sdoc sgra
"""The VOCABULARY a semantic is written in. Stdlib only, no `transitions`.

This layer is deliberately inert. A `Semantic` is a record an operator reads,
edits and argues with; nothing here runs a machine, validates a rung against
the grammar, or knows what a diagnostic is. `engine.py` is the only module in
this package that imports `transitions`, and keeping the declarations free of
it is what lets a machine file be reviewed as prose.

THE FIELD NAME IS DATA, NEVER A CONSTANT IN THE CODE. WORK-DEPTH-RENAME is
live, so `DEPTH` may not be spelled anywhere outside `machines/depth.py`.
Everything downstream keys off `Semantic.field`.

ORDER IS THE LADDER, NOT THE ALPHABET. `states` is written in the order the
values are meant to be climbed and is never sorted -- the position of a rung
IS the claim being made, and sorting it would silently rewrite the semantics
into alphabetical nonsense (`implemented` before `sketch`).
"""

from __future__ import annotations

from dataclasses import dataclass, field as dataclass_field
from typing import Iterable, Sequence

#: The vocabulary `Rule.kind` may use. Each answers a different question about
#: where the rule CAME FROM, which is the thing an operator reshaping these
#: needs to see first:
#:
#:   transcription  copied out of an accepted node; changing it means changing
#:                  that node, not this file.
#:   policy         asserted here, backed by nothing yet. Argue with it.
#:   derived        computed from the machine or the grammar; not authored.
#:   open           a QUESTION, deliberately unanswered. Carries no behaviour.
RULE_KINDS = ("transcription", "policy", "derived", "open")


@dataclass(frozen=True)
class State:
    """One value of one state field: the rung, how to say it, and why."""

    name: str
    label: str = ""
    note: str = ""

    def rendered_label(self) -> str:
        return self.label or self.name


@dataclass(frozen=True)
class Transition:
    """One legal move. `settled` is the operator's, and starts False.

    `rule_text` is the sentence a person would say to justify the move. It is
    NOT a docstring for the code: it is the thing being reviewed, and the
    board renders it beside the edge.
    """

    trigger: str
    source: str
    dest: str
    rule_text: str = ""
    settled: bool = False
    conditions: tuple[str, ...] = ()
    unless: tuple[str, ...] = ()


@dataclass(frozen=True)
class Rule:
    """A statement ABOUT the machine that the machine cannot itself carry.

    `transitions` says what may move; a `Rule` says why, or says that nobody
    has decided yet (`kind="open"`). Open rules are the point of the spike --
    they are how a question travels to the board instead of dying in a commit
    message.
    """

    id: str
    text: str
    kind: str = "policy"
    settled: bool = False
    cites: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if self.kind not in RULE_KINDS:
            raise ValueError(f"{self.id}: kind {self.kind!r} not in {RULE_KINDS}")


@dataclass(frozen=True)
class Semantic:
    """One state FIELD's lifecycle, in the SLICE-BEHAVIOUR-MODEL vocabulary.

    `subject` is left implicit: which node types carry this field is READ from
    the grammar rather than declared here, so adding the field to a ninth type
    needs no edit in this package.
    """

    field: str
    states: tuple[State, ...]
    transitions: tuple[Transition, ...] = ()
    rules: tuple[Rule, ...] = ()
    note: str = ""
    metadata: dict = dataclass_field(default_factory=dict)

    @property
    def initial(self) -> str:
        """THE FIRST RUNG, always.

        Not a separate declaration, and that is a guard rather than a
        shorthand: `transitions.add_ordered_transitions` ROTATES its sequence
        to begin at the machine's initial state, so an initial that is not the
        first element silently drops the first edge and invents a wrap-around
        one. Making the two the same value by construction removes the trap
        instead of documenting it.
        """
        return self.states[0].name

    def state_names(self) -> tuple[str, ...]:
        return tuple(state.name for state in self.states)


def ordered(
    states: Sequence[State] | Sequence[str],
    trigger: str,
    *,
    rule_text: str = "",
    settled: bool = False,
) -> tuple[Transition, ...]:
    """A forward-only ladder: each rung to the next, one trigger, no wrap.

    Hand-expanded rather than handed to `Machine.add_ordered_transitions`, and
    that is the whole reason this helper exists. Upstream's version defaults to
    `loop=True`, which closes the ladder into a ring by adding a last -> first
    edge -- for `AUTHORED_BY` that edge is a laundering path from `human` back
    to `llm`, which DEC-AUTHORSHIP-LADDER forbids outright. A shape that cannot
    be produced needs no flag remembered at every call site.
    """
    names = [
        state.name if isinstance(state, State) else str(state) for state in states
    ]
    return tuple(
        Transition(
            trigger=trigger,
            source=source,
            dest=dest,
            rule_text=rule_text,
            settled=settled,
        )
        for source, dest in zip(names, names[1:])
    )


def states_of(*rows: Iterable) -> tuple[State, ...]:
    """`(name, label, note)` tuples to `State`s, order preserved."""
    out = []
    for row in rows:
        values = list(row)
        out.append(State(*values))
    return tuple(out)
