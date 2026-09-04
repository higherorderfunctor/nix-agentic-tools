# cspell:ignore behaviour sdoc sgra
"""Temporary records adapting ``model.json`` to the spike interpreter.

The model document is the only declaration surface.  These records preserve
the old engine's input until WORK-SEMANTICS-STDLIB-INTERPRETER replaces that
engine; none of the lifecycle content is repeated here.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field as dataclass_field
from pathlib import Path

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


def load_semantics(path: Path) -> tuple[Semantic, ...]:
    """Adapt the ordered lifecycle declarations without changing their data."""
    document = json.loads(path.read_text())
    return tuple(
        Semantic(
            field=lifecycle["subject"]["field"],
            states=tuple(State(**state) for state in lifecycle["states"]),
            transitions=tuple(
                Transition(
                    trigger=transition["trigger"],
                    source=transition["from"],
                    dest=transition["to"],
                    rule_text=transition["rule_text"],
                    settled=transition["settled"],
                    conditions=tuple(transition["gates"]),
                )
                for transition in lifecycle["transitions"]
            ),
            rules=tuple(
                Rule(
                    id=rule["id"],
                    text=rule["text"],
                    kind=rule["kind"],
                    settled=rule["settled"],
                    cites=tuple(rule["cites"]),
                )
                for rule in lifecycle["rules"]
            ),
        )
        for lifecycle in document["lifecycles"]
    )
