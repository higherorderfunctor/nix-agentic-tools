#!/usr/bin/env python3
# cspell:ignore PYTHONDONTWRITEBYTECODE behaviour behaviourally mermaid sdoc sgra synthesises
"""Contracts for dev/scripts/sdoc_semantics/ (the state-field semantics spike).

    strictdoc-grammar-extract dev/scripts/test_sdoc_semantics.py

THE INTERPRETER. Anything carrying `transitions` runs this -- the dev shell's
`python3` does, and so does `strictdoc-grammar-extract`. CI uses the latter,
because it is the same runner every scribe program and every other strictdoc
check already uses, so one delivery seam is exercised rather than two.

EVERY NEGATIVE CONTRACT CARRIES ITS POSITIVE CONTROL, and here that is not a
formality: the three `transitions` traps this package avoids are avoided BY
CONSTRUCTION, so an assertion that the bad shape is absent would pass just as
happily against a library that never had the trap. Each one therefore also
demonstrates the trap firing on a machine built the naive way, in the same
contract, so the guard is shown to be guarding something.

  1. `add_ordered_transitions` ROTATES to the machine's initial, dropping the
     first edge and inventing a wrap-around one.
  2. its `loop=True` default closes the ladder into a ring.
  3. `auto_transitions=True` (Machine's default) synthesises `to_<state>()`
     triggers that never appear in `markup` but DO appear in `get_triggers`,
     so no state is ever terminal.

The grammar read here is the REPOSITORY's, not a fixture, because the whole
claim of `applies_to` is that it is derived rather than written down.
"""

from __future__ import annotations

import dataclasses
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from transitions.extensions.markup import MarkupMachine  # noqa: E402

from scribe_grammar import parse_sgra  # noqa: E402
from sdoc_semantics import (  # noqa: E402
    SCHEMA,
    SEMANTICS,
    Rule,
    Semantic,
    State,
    Transition,
    build_machine,
    diagnostics,
    mermaid,
    ordered,
    payload,
    semantics,
    states_of,
    terminal_states,
)
from sdoc_semantics import cli as semantics_cli  # noqa: E402
from sdoc_semantics.machines import depth as depth_machine  # noqa: E402

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
GRAMMAR = parse_sgra(REPO_ROOT / "docs" / "sdoc" / "grammar.sgra")
PAYLOAD = payload(semantics(), GRAMMAR)

PASSED: list = []


def contract(name: str):
    def wrap(function):
        def run():
            function()
            PASSED.append(name)
            print(f"  ok  {name}")

        run.contract_name = name
        return run

    return wrap


def fixture_grammar(tag_fields: dict) -> dict:
    """A `parse_sgra`-shaped grammar: `{TAG: [(field, options), ...]}`."""
    return {
        tag: {
            "prefix": tag[:3] + "-",
            "fields": [
                {"name": name, "kind": "SingleChoice", "options": list(options),
                 "required": True}
                for name, options in fields
            ],
            "roles": [],
        }
        for tag, fields in tag_fields.items()
    }


def edges(semantic: Semantic) -> list:
    return [(t.source, t.dest) for t in semantic.transitions]


# ── the three transitions traps, each with the trap demonstrated ─────────


@contract("no machine closes into a ring (loop=True is never reachable)")
def test_no_wrap_around_edge() -> None:
    for semantic in semantics():
        names = semantic.state_names()
        assert (names[-1], names[0]) not in edges(semantic), semantic.field
        assert all(t.dest != semantic.initial for t in semantic.transitions), (
            f"{semantic.field}: something re-enters the initial state"
        )

    # POSITIVE CONTROL: upstream's helper adds exactly that edge by DEFAULT,
    # which for AUTHORED_BY would be a laundering path from human back to llm.
    naive = MarkupMachine(
        model=None, states=["a", "b", "c"], initial="a", auto_transitions=False
    )
    naive.add_ordered_transitions(states=["a", "b", "c"], trigger="go")
    ring = [(t["source"], t["dest"]) for t in naive.markup["transitions"]]
    assert ("c", "a") in ring, ring


@contract("initial is the first rung, so nothing rotates")
def test_initial_is_the_first_rung() -> None:
    for semantic in semantics():
        assert semantic.initial == semantic.states[0].name, semantic.field
        assert edges(semantic)[0][0] == semantic.initial, semantic.field

    # POSITIVE CONTROL: with initial NOT first, add_ordered_transitions rotates
    # the sequence -- the a->b edge is gone and a c->a edge nobody wrote is
    # there. This is why `Semantic.initial` is a property and not a field.
    rotated = MarkupMachine(
        model=None, states=["a", "b", "c"], initial="b", auto_transitions=False
    )
    rotated.add_ordered_transitions(states=["a", "b", "c"], trigger="go", loop=False)
    pairs = [(t["source"], t["dest"]) for t in rotated.markup["transitions"]]
    assert ("a", "b") not in pairs, pairs
    assert ("c", "a") in pairs, pairs


@contract("auto_transitions is off, so terminal states are real")
def test_no_auto_transitions() -> None:
    for semantic in semantics():
        machine = build_machine(semantic)
        for name in semantic.state_names():
            assert not any(
                trigger.startswith("to_") for trigger in machine.get_triggers(name)
            ), (semantic.field, name, machine.get_triggers(name))
        assert terminal_states(semantic, machine), semantic.field

    # POSITIVE CONTROL: the default synthesises to_<state> for every state, and
    # `markup` does NOT show them -- so a reviewer reading the payload would
    # see nothing wrong while every terminal list silently emptied.
    leaky = MarkupMachine(model=None, states=["a", "b"], initial="a")
    leaky.add_transition("go", "a", "b")
    assert "to_a" in leaky.get_triggers("b"), leaky.get_triggers("b")
    assert not any(
        t["trigger"].startswith("to_") for t in leaky.markup["transitions"]
    ), leaky.markup["transitions"]


# ── the diagnostics ──────────────────────────────────────────────────────


@contract("an unreachable state is reported, and a reachable one is not")
def test_unreachable_state() -> None:
    stranded = Semantic(
        field="F",
        states=states_of(("a",), ("b",), ("orphan",)),
        transitions=(Transition(trigger="go", source="a", dest="b"),),
    )
    found = diagnostics(stranded, build_machine(stranded))
    assert any("orphan" in message and "unreachable" in message for message in found), found

    # POSITIVE CONTROL: the same shape with the edge added reports nothing.
    joined = Semantic(
        field="F",
        states=stranded.states,
        transitions=stranded.transitions
        + (Transition(trigger="go", source="b", dest="orphan"),),
    )
    assert not [m for m in diagnostics(joined, build_machine(joined)) if "unreachable" in m]


@contract("two transitions on one trigger from one state are reported")
def test_ambiguous_trigger() -> None:
    forked = Semantic(
        field="F",
        states=states_of(("a",), ("b",), ("c",)),
        transitions=(
            Transition(trigger="go", source="a", dest="b"),
            Transition(trigger="go", source="a", dest="c"),
        ),
    )
    found = diagnostics(forked, build_machine(forked))
    assert any("ambiguous" in message for message in found), found

    # POSITIVE CONTROL: the SAME fork on two DIFFERENT triggers is legal, and
    # is exactly what STATUS does -- so this must not fire on it.
    named = Semantic(
        field="F",
        states=forked.states,
        transitions=(
            Transition(trigger="accept", source="a", dest="b"),
            Transition(trigger="reject", source="a", dest="c"),
        ),
    )
    assert not [m for m in diagnostics(named, build_machine(named)) if "ambiguous" in m]
    assert not [
        m for m in PAYLOAD["machines"]["STATUS"]["diagnostics"] if "ambiguous" in m
    ]


@contract("a lifecycle with no terminal state is reported")
def test_no_terminal_state() -> None:
    ring = Semantic(
        field="F",
        states=states_of(("a",), ("b",)),
        transitions=(
            Transition(trigger="go", source="a", dest="b"),
            Transition(trigger="go", source="b", dest="a"),
        ),
    )
    found = diagnostics(ring, build_machine(ring))
    assert any("no terminal state" in message for message in found), found

    # POSITIVE CONTROL: drop the closing edge and the complaint goes away.
    line = Semantic(field="F", states=ring.states, transitions=ring.transitions[:1])
    assert not [m for m in diagnostics(line, build_machine(line)) if "terminal" in m]


@contract("a state the grammar does not declare is reported")
def test_grammar_vocabulary_cross_check() -> None:
    """SLICE-BEHAVIOUR-MODEL's cross-check, and the one an operator hand-editing
    a rung trips first."""
    grammar = fixture_grammar({"THING": [("F", ["a", "b"])]})
    typo = Semantic(
        field="F",
        states=states_of(("a",), ("bb",)),
        transitions=(Transition(trigger="go", source="a", dest="bb"),),
    )
    found = diagnostics(typo, build_machine(typo), grammar)
    assert any("does not declare" in message for message in found), found

    # POSITIVE CONTROL, twice: the corrected spelling is silent, and so is the
    # REAL corpus -- every rung of every machine is a value the grammar knows.
    fixed = Semantic(
        field="F",
        states=states_of(("a",), ("b",)),
        transitions=(Transition(trigger="go", source="a", dest="b"),),
    )
    assert not diagnostics(fixed, build_machine(fixed), grammar)
    for field, entry in PAYLOAD["machines"].items():
        assert entry["diagnostics"] == [], (field, entry["diagnostics"])


# ── the payload contract ─────────────────────────────────────────────────


@contract("the payload is sdoc-semantics/1, exactly as the board reads it")
def test_payload_shape() -> None:
    assert PAYLOAD["schema"] == SCHEMA == "sdoc-semantics/1", PAYLOAD["schema"]
    assert set(PAYLOAD) == {"schema", "machines", "by_type"}, sorted(PAYLOAD)
    for field, entry in PAYLOAD["machines"].items():
        assert entry["field"] == field, entry
        assert set(entry) == {
            "field", "applies_to", "initial", "terminal", "states",
            "transitions", "rules", "diagnostics",
        }, sorted(entry)
        for state in entry["states"]:
            assert set(state) <= {"name", "label", "note"}, sorted(state)
            assert state["name"] and state["label"], state
        for transition in entry["transitions"]:
            assert set(transition) == {
                "trigger", "source", "dest", "conditions", "unless",
                "rule_text", "settled",
            }, sorted(transition)
            assert transition["settled"] is False, transition
        for rule in entry["rules"]:
            assert set(rule) == {"id", "text", "kind", "settled", "cites"}, sorted(rule)
    # JSON-able, which is the actual requirement -- the board eats this.
    assert json.loads(json.dumps(PAYLOAD)) == PAYLOAD


@contract("build_payload is the seam every consumer reaches for")
def test_build_payload_is_the_seam() -> None:
    """The board, `scribe semantics` and the CLI all enter here, so this one
    call has to be the whole contract -- a parsed grammar in, sdoc-semantics/1
    out, with no registry plumbing on the caller's side."""
    import sdoc_semantics

    assert sdoc_semantics.build_payload(GRAMMAR) == PAYLOAD
    assert semantics_cli.build_payload(GRAMMAR) == PAYLOAD


@contract("states are in LADDER order, not alphabetical")
def test_ladder_order_survives() -> None:
    names = [state["name"] for state in PAYLOAD["machines"]["DEPTH"]["states"]]
    assert names[0] == "sketch" and names[-1] == "verified", names
    assert names != sorted(names), names
    assert PAYLOAD["machines"]["STATUS"]["states"][0]["name"] == "open"


@contract("by_type is the reverse index, and lists every grammar tag")
def test_by_type_reverse_index() -> None:
    assert set(PAYLOAD["by_type"]) == set(GRAMMAR), sorted(PAYLOAD["by_type"])
    for field, entry in PAYLOAD["machines"].items():
        for tag in entry["applies_to"]:
            assert field in PAYLOAD["by_type"][tag], (tag, field)
    for tag, fields in PAYLOAD["by_type"].items():
        for field in fields:
            assert tag in PAYLOAD["machines"][field]["applies_to"], (tag, field)
    # COMMENTARY carries STANDING, which has no machine yet -- so it is present
    # with only AUTHORED_BY rather than absent. Indexing it must not KeyError.
    assert PAYLOAD["by_type"]["COMMENTARY"] == ["AUTHORED_BY"], PAYLOAD["by_type"]


# ── derivation from the grammar, never hard-coded ────────────────────────


@contract("applies_to is read from the real grammar")
def test_applies_to_matches_the_corpus() -> None:
    assert PAYLOAD["machines"]["DEPTH"]["applies_to"] == [
        "MECHANISM", "REQUIREMENT", "EVIDENCE", "USE_CASE", "NARRATIVE", "WORK",
    ], PAYLOAD["machines"]["DEPTH"]["applies_to"]
    assert PAYLOAD["machines"]["STATUS"]["applies_to"] == ["DECISION"]
    assert PAYLOAD["machines"]["AUTHORED_BY"]["applies_to"] == list(GRAMMAR)


@contract("applies_to follows a DIFFERENT grammar, so it is derived")
def test_applies_to_is_not_a_constant() -> None:
    """The control the previous contract cannot be: asserting six tags is also
    what a hard-coded list would do."""
    grammar = fixture_grammar(
        {
            "ONLY": [("DEPTH", list(depth_machine.SEMANTIC.state_names()))],
            "OTHER": [("AUTHORED_BY", ["llm", "llm-accepted", "llm-adopted", "human"])],
        }
    )
    other = payload(semantics(), grammar)
    assert other["machines"]["DEPTH"]["applies_to"] == ["ONLY"]
    assert other["machines"]["STATUS"]["applies_to"] == []
    assert other["by_type"] == {"ONLY": ["DEPTH"], "OTHER": ["AUTHORED_BY"]}


@contract("the field name is data: renaming it moves everything downstream")
def test_field_name_is_data() -> None:
    """WORK-DEPTH-RENAME is live, so a rename must be ONE edit inside
    machines/depth.py. Asserted behaviourally rather than by grepping for the
    word: prose mentions it everywhere, and a grep would either fail on those
    or be so narrow it proved nothing. Rename the field on the record and every
    downstream key has to follow it, with no leftover under the old name."""
    renamed = dataclasses.replace(depth_machine.SEMANTIC, field="RIPENESS")
    grammar = fixture_grammar(
        {"THING": [("RIPENESS", list(renamed.state_names()))]}
    )
    data = payload([renamed], grammar)
    assert list(data["machines"]) == ["RIPENESS"], list(data["machines"])
    assert data["machines"]["RIPENESS"]["field"] == "RIPENESS"
    assert data["machines"]["RIPENESS"]["applies_to"] == ["THING"]
    assert data["by_type"] == {"THING": ["RIPENESS"]}, data["by_type"]
    assert "RIPENESS" in semantics_cli.render(data, "THING")
    assert data["machines"]["RIPENESS"]["diagnostics"] == []


# ── declarations, rendering and the front ends ───────────────────────────


@contract("a rule kind outside the vocabulary is refused")
def test_rule_kind_is_closed() -> None:
    for semantic in semantics():
        for rule in semantic.rules:
            assert rule.kind in ("transcription", "policy", "derived", "open"), rule
    try:
        Rule(id="X", text="y", kind="vibes")
    except ValueError:
        pass
    else:
        raise AssertionError("Rule accepted a kind outside RULE_KINDS")


@contract("every machine carries at least one OPEN question")
def test_open_questions_travel() -> None:
    """The spike's actual deliverable. A machine with no open rule is claiming
    to be finished, and none of these are."""
    for semantic in semantics():
        assert any(rule.kind == "open" for rule in semantic.rules), semantic.field
        assert all(not t.settled for t in semantic.transitions), semantic.field


@contract("ordered() expands adjacent pairs and nothing else")
def test_ordered_helper() -> None:
    built = ordered(states_of(("a",), ("b",), ("c",)), "go")
    assert [(t.source, t.dest) for t in built] == [("a", "b"), ("b", "c")]
    assert {t.trigger for t in built} == {"go"}
    assert ordered([State("only")], "go") == ()


@contract("mermaid renders a stateDiagram-v2 with every edge")
def test_mermaid() -> None:
    drawn = mermaid(SEMANTICS["STATUS"])
    assert drawn is not None, "the diagrams extra did not load"
    assert "stateDiagram-v2" in drawn, drawn
    for transition in SEMANTICS["STATUS"].transitions:
        assert (
            f"{transition.source} --> {transition.dest}: {transition.trigger}" in drawn
        ), drawn


@contract("the renderer shows the rules and the open flag")
def test_render() -> None:
    text = semantics_cli.render(PAYLOAD, "DEPTH")
    assert "DEPTH-REGRESSION-UNDECIDED" in text, text
    assert "[OPEN]" in text, text
    assert "MECHANISM" in text, text
    # A TYPE selector goes through by_type, the same index the board reads.
    assert "STATUS" in semantics_cli.render(PAYLOAD, "DECISION")
    assert "STATUS" not in semantics_cli.render(PAYLOAD, "WORK")


@contract("an unknown selector is refused, naming the choices")
def test_selector_refusal() -> None:
    try:
        semantics_cli.select(PAYLOAD, "NOPE")
    except SystemExit as exc:
        assert "DEPTH" in str(exc.code) and "DECISION" in str(exc.code), exc.code
    else:
        raise AssertionError("an unknown selector was accepted")


def run_scribe(*arguments: str, **overrides) -> subprocess.CompletedProcess:
    """`scribe` in a child process that CANNOT reach a daemon.

    PYTHONPATH is carried over deliberately: on strictdoc's venv that variable
    IS the delivery of `transitions` and of this repository's own modules
    (packages/strictdoc-grammar/lib/mkExtract.nix splices it onto the wrapper),
    so a child started without it is not testing the shipped environment.
    """
    environment = {
        "PATH": "/nonexistent",
        "HOME": "/nonexistent",
        "SCRIBE_SOCKET": "/nonexistent/scribe.sock",
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONPATH": os.environ.get("PYTHONPATH", ""),
    }
    environment.update(overrides)
    return subprocess.run(
        [sys.executable, str(REPO_ROOT / "dev/scripts/scribe_cmd.py"),
         "--root", str(REPO_ROOT), *arguments],
        capture_output=True, text=True, env=environment,
    )


@contract("scribe semantics answers with no daemon in sight")
def test_scribe_subcommand_short_circuits() -> None:
    """It short-circuits BEFORE call_for_root, so it must answer with the
    socket pointed at nothing -- which is the state an operator is in when the
    graph will not load and they want to know what a value MEANS."""
    result = run_scribe("semantics", "--json", "DEPTH")
    assert result.returncode == 0, (result.returncode, result.stderr)
    data = json.loads(result.stdout)
    assert data["schema"] == SCHEMA, data
    assert list(data["machines"]) == ["DEPTH"], list(data["machines"])
    assert "daemon" not in result.stderr, result.stderr


@contract("a missing engine costs one subcommand, not a traceback")
def test_scribe_without_the_engine() -> None:
    """POSITIVE CONTROL for the lazy import in `scribe_cmd.run_semantics`.

    Stripping PYTHONPATH removes `transitions` on strictdoc's venv and removes
    nothing on an interpreter that has it built in, so the contract is written
    to hold on BOTH: either it still answers, or it refuses in ONE line that
    names what is missing and how to get it. What it may never do is exit on an
    ImportError traceback -- `scribe set` must survive an absent engine."""
    result = run_scribe("semantics", "DEPTH", PYTHONPATH="")
    if result.returncode == 0:
        assert "DEPTH" in result.stdout, result.stdout
        return
    assert result.returncode == 1, result.returncode
    assert "Traceback" not in result.stderr, result.stderr
    assert "transitions" in result.stderr, result.stderr
    assert "strictdoc-grammar-extract" in result.stderr, result.stderr


def main() -> int:
    contracts = [
        value
        for name, value in sorted(globals().items())
        if name.startswith("test_") and callable(value)
    ]
    print(f"sdoc_semantics contracts: {len(contracts)}")
    for check in contracts:
        check()
    print(f"{len(PASSED)} contract(s) passed")
    assert len(PASSED) == len(contracts)
    assert len(SEMANTICS) == 3, sorted(SEMANTICS)
    return 0


if __name__ == "__main__":
    sys.exit(main())
