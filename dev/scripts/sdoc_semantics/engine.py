# cspell:ignore behaviour diffable mermaid sdoc sgra synthesises
"""The ONLY module here that imports `transitions`, and the only one that runs.

WHAT IT IS FOR. A `Semantic` (see `declare.py`) is a claim. This module turns
that claim into a real `transitions` machine so the claim can be INTERROGATED
rather than believed: which states are terminal is asked of the machine
(`get_triggers(state) == []`), not asserted in the declaration, and the three
eval-time diagnostics SLICE-BEHAVIOUR-MODEL owes are computed here.

── The waiver ───────────────────────────────────────────────────────────────

DEC-LAYER-STACK rules that SEMANTICS ARE NEVER WRITTEN DIRECTLY INTO A TOOL --
a rule living in the body of a script rather than in an L3 definition that
decomposes onto L2 is a layering violation regardless of whether the rule is
correct. This package IS that violation, WAIVED EXPLICITLY BY THE OPERATOR for
this spike ("for the spike the semantics can be written in direct python").
The waiver is for the spike only. `machines/` is a transcription surface for
the operator to reshape by hand; when SLICE-BEHAVIOUR-MODEL lands, these files
become the fixture that the typed Nix surface has to reproduce, not the thing
that ships.

── Three measured traps in `transitions` 0.9.3, all avoided by construction ─

1. `add_ordered_transitions` ROTATES its sequence to start at the machine's
   `initial`. With `initial="b"` over `[a, b, c]` it yields `b->c` and `c->a`:
   the `a->b` edge is GONE and a wrap-around edge nobody asked for is there.
   Avoided by `declare.ordered`, which expands adjacent pairs itself, and by
   `Semantic.initial` being the first rung by construction.
2. `loop=True` is that helper's DEFAULT, closing every ladder into a ring.
   Same avoidance -- the shape cannot be produced here.
3. `auto_transitions=True` is `Machine`'s DEFAULT and synthesises a
   `to_<state>()` trigger for every state. Those triggers do not appear in
   `markup`, so a reviewer reading the markup sees nothing wrong, but
   `get_triggers()` returns them and NO STATE IS EVER TERMINAL. Since terminal
   detection here is exactly that call, this default would silently empty the
   `terminal` list of every machine. Passed off explicitly below.

`model=None` is also deliberate: with a model attached, `markup["models"]`
carries an `id()` that churns between runs, and the payload is meant to be
diffable.
"""

from __future__ import annotations

from typing import Iterable, Mapping, Optional, Sequence

from transitions.extensions.markup import MarkupMachine

from .declare import Semantic

#: The payload version the board and every other consumer agree on. Bump it
#: when a key changes meaning, never when a machine changes.
SCHEMA = "sdoc-semantics/1"


def build_machine(semantic: Semantic) -> MarkupMachine:
    """One `Semantic` as a live machine. See the three traps in the header."""
    machine = MarkupMachine(
        model=None,
        states=list(semantic.state_names()),
        initial=semantic.initial,
        auto_transitions=False,
    )
    for transition in semantic.transitions:
        machine.add_transition(
            trigger=transition.trigger,
            source=transition.source,
            dest=transition.dest,
            conditions=list(transition.conditions) or None,
            unless=list(transition.unless) or None,
        )
    return machine


def terminal_states(semantic: Semantic, machine: MarkupMachine) -> list[str]:
    """States nothing can leave, ASKED of the machine rather than declared."""
    return [
        name for name in semantic.state_names() if not machine.get_triggers(name)
    ]


def reachable_states(semantic: Semantic) -> set[str]:
    """Every state a walk from `initial` can arrive at, `initial` included."""
    reached = {semantic.initial}
    frontier = [semantic.initial]
    while frontier:
        current = frontier.pop()
        for transition in semantic.transitions:
            if transition.source == current and transition.dest not in reached:
                reached.add(transition.dest)
                frontier.append(transition.dest)
    return reached


def applies_to(field: str, grammar: Mapping) -> list[str]:
    """Which node types carry this field, READ from the parsed grammar.

    Never hard-coded: `DEPTH` is on six of the eight types today and the set
    moves whenever `packages/strictdoc-grammar/values.nix` does. Grammar
    declaration order is preserved rather than sorted, so the list reads the
    way `docs/sdoc/grammar.sgra` does.
    """
    return [
        tag
        for tag, element in grammar.items()
        if any(entry["name"] == field for entry in element.get("fields", []))
    ]


def grammar_options(field: str, grammar: Mapping) -> dict[str, list[str]]:
    """`{tag: declared option list}` for every type carrying this field."""
    out: dict[str, list[str]] = {}
    for tag, element in grammar.items():
        for entry in element.get("fields", []):
            if entry["name"] == field:
                out[tag] = list(entry.get("options", []))
    return out


def diagnostics(
    semantic: Semantic,
    machine: MarkupMachine,
    grammar: Optional[Mapping] = None,
) -> list[str]:
    """The eval-time complaints SLICE-BEHAVIOUR-MODEL owes, plus one.

    Three are its own list, verbatim: a state no transition can reach, a
    lifecycle with no initial or no terminal state, and two transitions firing
    on one trigger. Each is REPORTED, never raised -- a half-written machine
    has to reach the board, because the board is where it gets finished.

    The fourth is the grammar cross-check the same node demands of the typed
    surface ("a state naming a value the grammar does not declare"). It is here
    because it is the one an operator hand-editing rungs will trip first, and
    it costs a dict lookup.
    """
    found: list[str] = []

    if not semantic.states:
        found.append(f"{semantic.field}: no states declared, so no initial state")
        return found

    unreachable = [
        name for name in semantic.state_names() if name not in reachable_states(semantic)
    ]
    for name in unreachable:
        found.append(
            f"{semantic.field}: state {name!r} is unreachable from "
            f"{semantic.initial!r}"
        )

    if not terminal_states(semantic, machine):
        found.append(
            f"{semantic.field}: no terminal state -- every state can still be left"
        )

    seen: dict[tuple[str, str], str] = {}
    for transition in semantic.transitions:
        key = (transition.source, transition.trigger)
        if key in seen:
            found.append(
                f"{semantic.field}: trigger {transition.trigger!r} fires from "
                f"{transition.source!r} to both {seen[key]!r} and "
                f"{transition.dest!r} -- ambiguous"
            )
        else:
            seen[key] = transition.dest

    if grammar is not None:
        declared = set(semantic.state_names())
        for tag, options in grammar_options(semantic.field, grammar).items():
            extra = declared - set(options)
            missing = set(options) - declared
            if extra:
                found.append(
                    f"{semantic.field}: {tag} does not declare "
                    f"{sorted(extra)} -- the grammar knows {options}"
                )
            if missing:
                found.append(
                    f"{semantic.field}: {tag} declares {sorted(missing)}, which "
                    f"this lifecycle has no state for"
                )

    return found


def machine_payload(semantic: Semantic, grammar: Mapping) -> dict:
    """One machine's entry in the payload. See `payload` for the contract."""
    machine = build_machine(semantic)
    states = []
    for state in semantic.states:
        entry = {"name": state.name, "label": state.rendered_label()}
        if state.note:
            entry["note"] = state.note
        states.append(entry)
    return {
        "field": semantic.field,
        "applies_to": applies_to(semantic.field, grammar),
        "initial": semantic.initial,
        "terminal": terminal_states(semantic, machine),
        # LADDER ORDER, deliberately not alphabetical: the position of a rung
        # is the claim. A consumer that sorts this has changed the semantics.
        "states": states,
        "transitions": [
            {
                "trigger": transition.trigger,
                "source": transition.source,
                "dest": transition.dest,
                "conditions": list(transition.conditions),
                "unless": list(transition.unless),
                "rule_text": transition.rule_text,
                "settled": transition.settled,
            }
            for transition in semantic.transitions
        ],
        "rules": [
            {
                "id": rule.id,
                "text": rule.text,
                "kind": rule.kind,
                "settled": rule.settled,
                "cites": list(rule.cites),
            }
            for rule in semantic.rules
        ],
        "diagnostics": diagnostics(semantic, machine, grammar),
    }


def payload(semantics: Iterable[Semantic], grammar: Mapping) -> dict:
    """THE CONTRACT. `sdoc-semantics/1`, as the board consumes it.

        {"schema": "sdoc-semantics/1",
         "machines": {"<FIELD>": {...}},
         "by_type": {"<TYPE>": ["<FIELD>", ...]}}

    `by_type` is the reverse index, and it lists EVERY grammar tag -- a type
    carrying no state field gets an empty list rather than being absent, so a
    consumer can index it without a guard.
    """
    machines = {
        semantic.field: machine_payload(semantic, grammar) for semantic in semantics
    }
    by_type: dict[str, list[str]] = {tag: [] for tag in grammar}
    for field, entry in machines.items():
        for tag in entry["applies_to"]:
            by_type.setdefault(tag, []).append(field)
    return {"schema": SCHEMA, "machines": machines, "by_type": by_type}


def mermaid(semantic: Semantic) -> Optional[str]:
    """A `stateDiagram-v2` string, or None when the extra is unavailable.

    Guarded because `transitions.extensions.diagrams` is an optional surface:
    the mermaid engine needs no graphviz, but a future build could still ship
    the core without the extension, and a missing DIAGRAM must never take down
    a payload the board needs for its listing.

    A throwaway model is attached, unlike everywhere else in this module:
    `get_graph()` is a MODEL method and `GraphMachine(model=None)` raises
    `IndexError` on the empty model list. Nothing reads the model afterwards.
    """
    try:
        from transitions.extensions.diagrams import GraphMachine
    except Exception:  # pragma: no cover -- optional extra
        return None

    class _Subject:
        pass

    subject = _Subject()
    try:
        graph = GraphMachine(
            model=subject,
            states=list(semantic.state_names()),
            initial=semantic.initial,
            auto_transitions=False,
            graph_engine="mermaid",
        )
        for transition in semantic.transitions:
            graph.add_transition(
                trigger=transition.trigger,
                source=transition.source,
                dest=transition.dest,
            )
        return subject.get_graph().draw(None)
    except Exception:  # pragma: no cover -- optional extra
        return None


def markup_of(semantic: Semantic) -> dict:
    """The raw `transitions` markup, for a test or a debugging session."""
    return build_machine(semantic).markup


def sequence_of(names: Sequence[str]) -> list[tuple[str, str]]:
    """`[(source, dest), ...]` for a name list. Test-facing convenience."""
    return list(zip(names, names[1:]))
