#!/usr/bin/env python3
# cspell:ignore PYTHONDONTWRITEBYTECODE sdoc sgra unrelate
"""Executable contracts for the standard-library semantics interpreter."""

from __future__ import annotations

import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

from scribe_grammar import parse_sgra  # noqa: E402
from sdoc_semantics import (  # noqa: E402
    MODEL_PATH,
    PAYLOAD_KEYS,
    PREDICATE_OPERATIONS,
    SCHEMA,
    Interpreter,
    ModelError,
    adapt_graph,
    build_payload,
    diagnostics,
    evaluate,
    gate_placement,
    load_model,
    mermaid,
    payload,
    validate_model,
)

REPO_ROOT = Path(__file__).resolve().parents[2]
GRAMMAR = parse_sgra(REPO_ROOT / "docs" / "sdoc" / "grammar.sgra")
SHIPPED = load_model(MODEL_PATH, GRAMMAR)
SHIPPED_PAYLOAD = build_payload(GRAMMAR)
EXPECTED_MACHINES = json.loads(
    (
        Path(__file__).parent
        / "sdoc_semantics"
        / "tests"
        / "fixtures"
        / "shipped-machines.json"
    ).read_text()
)
PASSED: list[str] = []


def contract(name: str):
    def wrap(function):
        def run():
            function()
            PASSED.append(name)
            print(f"  ok  {name}")

        run.contract_name = name
        return run

    return wrap


def empty_model() -> dict:
    return {
        "schema": "sdoc-semantics-model/1",
        "model_version": "fixture",
        "lifecycles": [],
        "actors": [],
        "commands": [],
        "events": [],
        "operations": [],
        "gates": [],
        "relation_contracts": [],
        "checkpoints": [],
        "milestones": [],
        "flows": [],
        "rules": [],
    }


def lifecycle(
    name="L",
    field="F",
    states=("a", "b"),
    transitions=(),
    *,
    initial="a",
    terminal=("b",),
    subject=None,
) -> dict:
    return {
        "name": name,
        "subject": subject or {"kind": "field", "field": field},
        "states": [
            {"name": state, "label": state, "note": f"state {state}"}
            for state in states
        ],
        "initial": initial,
        "terminal": list(terminal),
        "transitions": list(transitions),
    }


def transition(
    trigger="go", source="a", dest="b", *, gates=(), writes=(), emits=()
) -> dict:
    return {
        "trigger": trigger,
        "from": source,
        "to": dest,
        "gates": list(gates),
        "writes": list(writes),
        "emits": list(emits),
        "rule_text": "fixture move",
        "settled": False,
    }


def node(uid="N", node_type="WORK", **fields) -> dict:
    return {"uid": uid, "type": node_type, "fields": fields}


def graph(*nodes, edges=()) -> dict:
    return {"nodes": {row["uid"]: row for row in nodes}, "edges": list(edges)}


def fixture_model(*, gate=None, command=True) -> dict:
    model = empty_model()
    gates = [gate] if gate else []
    model["gates"] = gates
    model["lifecycles"] = [
        lifecycle(transitions=[transition(gates=[gate["name"]] if gate else [])])
    ]
    if command:
        model["commands"] = [
            {"name": "move", "lifecycle": "L", "trigger": "go", "actor": None}
        ]
    return model


def assert_shipped_diagnostics_silent(fragment: str) -> None:
    found = [
        message
        for row in SHIPPED["lifecycles"]
        for message in diagnostics(row, GRAMMAR)
        if fragment in message
    ]
    assert found == [], found


PREDICATE_GRAPH = graph(
    node("A", "WORK", AUTHORED_BY="human-adopted", FLAG="yes"),
    node("B", "REQUIREMENT", AUTHORED_BY="human", FLAG="yes"),
    node("C", "EVIDENCE", AUTHORED_BY="llm", FLAG="no"),
    node("D", "WORK", AUTHORED_BY="human-adopted", FLAG="yes"),
    edges=(
        {"role": "Assumes", "source": "A", "target": "B"},
        {"role": "Assumes", "source": "A", "target": "C"},
        {"role": "Assumes", "source": "D", "target": "B"},
    ),
)
PREDICATE_NODE = PREDICATE_GRAPH["nodes"]["A"]


@contract("field_is has positive and negative controls")
def test_field_is() -> None:
    assert evaluate(
        {"op": "field_is", "field": "FLAG", "value": "yes"},
        PREDICATE_NODE,
        PREDICATE_GRAPH,
        "human",
        SHIPPED,
    )
    assert not evaluate(
        {"op": "field_is", "field": "FLAG", "value": "no"},
        PREDICATE_NODE,
        PREDICATE_GRAPH,
        "human",
        SHIPPED,
    )


@contract("field_at_least uses ladder rank in both directions")
def test_field_at_least() -> None:
    assert evaluate(
        {"op": "field_at_least", "field": "AUTHORED_BY", "value": "human-adopted"},
        PREDICATE_NODE,
        PREDICATE_GRAPH,
        "human",
        SHIPPED,
    )
    assert not evaluate(
        {"op": "field_at_least", "field": "AUTHORED_BY", "value": "human"},
        PREDICATE_NODE,
        PREDICATE_GRAPH,
        "human",
        SHIPPED,
    )


@contract("has_relation checks direction and optional target type")
def test_has_relation() -> None:
    assert evaluate(
        {"op": "has_relation", "role": "Assumes", "direction": "out", "target_type": "REQUIREMENT"},
        PREDICATE_NODE,
        PREDICATE_GRAPH,
        "human",
        SHIPPED,
    )
    assert not evaluate(
        {"op": "has_relation", "role": "Assumes", "direction": "in", "target_type": "REQUIREMENT"},
        PREDICATE_NODE,
        PREDICATE_GRAPH,
        "human",
        SHIPPED,
    )


@contract("all_related says explicitly what an empty set means")
def test_all_related() -> None:
    common = {
        "op": "all_related",
        "role": "Assumes",
        "direction": "out",
        "predicate": {"op": "field_is", "field": "FLAG", "value": "yes"},
    }
    assert evaluate(
        dict(common, empty="fail"), PREDICATE_GRAPH["nodes"]["D"],
        PREDICATE_GRAPH, "human", SHIPPED,
    )
    assert evaluate(
        dict(common, empty="pass"),
        PREDICATE_GRAPH["nodes"]["C"],
        PREDICATE_GRAPH,
        "human",
        SHIPPED,
    )
    assert not evaluate(
        dict(common, empty="pass"),
        PREDICATE_NODE,
        PREDICATE_GRAPH,
        "human",
        SHIPPED,
    )
    assert not evaluate(
        dict(common, empty="fail"),
        PREDICATE_GRAPH["nodes"]["C"],
        PREDICATE_GRAPH,
        "human",
        SHIPPED,
    )


@contract("any_related says explicitly what an empty set means")
def test_any_related() -> None:
    common = {
        "op": "any_related",
        "role": "Assumes",
        "direction": "out",
        "predicate": {"op": "field_is", "field": "FLAG", "value": "no"},
    }
    assert not evaluate(
        dict(common, empty="pass"), PREDICATE_GRAPH["nodes"]["D"],
        PREDICATE_GRAPH, "human", SHIPPED,
    )
    assert evaluate(
        dict(common, empty="fail"),
        PREDICATE_NODE,
        PREDICATE_GRAPH,
        "human",
        SHIPPED,
    )
    assert not evaluate(
        dict(common, empty="fail"),
        PREDICATE_GRAPH["nodes"]["B"],
        PREDICATE_GRAPH,
        "human",
        SHIPPED,
    )
    assert evaluate(
        dict(common, empty="pass"),
        PREDICATE_GRAPH["nodes"]["B"],
        PREDICATE_GRAPH,
        "human",
        SHIPPED,
    )


@contract("actor_in has positive and negative controls")
def test_actor_in() -> None:
    predicate = {"op": "actor_in", "actors": ["human"]}
    assert evaluate(predicate, PREDICATE_NODE, PREDICATE_GRAPH, "human", SHIPPED)
    assert not evaluate(predicate, PREDICATE_NODE, PREDICATE_GRAPH, "llm", SHIPPED)


@contract("and has positive and negative controls")
def test_and() -> None:
    yes = {"op": "field_is", "field": "FLAG", "value": "yes"}
    no = {"op": "field_is", "field": "FLAG", "value": "no"}
    assert evaluate({"op": "and", "predicates": [yes, yes]}, PREDICATE_NODE, PREDICATE_GRAPH, "human", SHIPPED)
    assert not evaluate({"op": "and", "predicates": [yes, no]}, PREDICATE_NODE, PREDICATE_GRAPH, "human", SHIPPED)


@contract("or has positive and negative controls")
def test_or() -> None:
    yes = {"op": "field_is", "field": "FLAG", "value": "yes"}
    no = {"op": "field_is", "field": "FLAG", "value": "no"}
    assert evaluate({"op": "or", "predicates": [no, yes]}, PREDICATE_NODE, PREDICATE_GRAPH, "human", SHIPPED)
    assert not evaluate({"op": "or", "predicates": [no, no]}, PREDICATE_NODE, PREDICATE_GRAPH, "human", SHIPPED)


@contract("not has positive and negative controls")
def test_not() -> None:
    yes = {"op": "field_is", "field": "FLAG", "value": "yes"}
    no = {"op": "field_is", "field": "FLAG", "value": "no"}
    assert evaluate({"op": "not", "predicate": no}, PREDICATE_NODE, PREDICATE_GRAPH, "human", SHIPPED)
    assert not evaluate({"op": "not", "predicate": yes}, PREDICATE_NODE, PREDICATE_GRAPH, "human", SHIPPED)


@contract("the closed operation table and shipped empty gates are explicit")
def test_closed_operation_table() -> None:
    from sdoc_semantics.engine import _OPERATION_TABLE, _OPERATIONS

    assert set(PREDICATE_OPERATIONS) == set(_OPERATION_TABLE) == set(_OPERATIONS)
    assert all(callable(entry[1]) for entry in _OPERATION_TABLE.values())
    assert tuple(sorted(PREDICATE_OPERATIONS)) == PREDICATE_OPERATIONS
    assert len(PREDICATE_OPERATIONS) == 9
    assert SHIPPED["gates"] == []


@contract("an unreachable state is diagnosed beside silent shipped lifecycles")
def test_unreachable_diagnostic() -> None:
    row = lifecycle(states=("a", "b", "lost"), transitions=[transition()])
    assert any("unreachable" in message and "lost" in message for message in diagnostics(row))
    assert not [message for message in diagnostics(lifecycle(transitions=[transition()])) if "unreachable" in message]
    assert_shipped_diagnostics_silent("unreachable")


@contract("a missing initial is diagnosed beside silent shipped lifecycles")
def test_initial_diagnostic() -> None:
    row = lifecycle(transitions=[transition()], initial=None)
    assert any("no initial" in message for message in diagnostics(row))
    assert not [message for message in diagnostics(lifecycle(transitions=[transition()])) if "no initial" in message]
    assert_shipped_diagnostics_silent("no initial")


@contract("a missing terminal is diagnosed beside silent shipped lifecycles")
def test_terminal_diagnostic() -> None:
    row = lifecycle(transitions=[transition()], terminal=())
    assert any("no terminal" in message for message in diagnostics(row))
    declared_ring = lifecycle(
        transitions=[transition(), transition("back", "b", "a")],
        terminal=("b",),
    )
    assert not [
        message for message in diagnostics(declared_ring) if "no terminal" in message
    ]
    assert not [message for message in diagnostics(lifecycle(transitions=[transition()])) if "no terminal" in message]
    assert_shipped_diagnostics_silent("no terminal")


@contract("ambiguous dispatch is diagnosed beside silent shipped lifecycles")
def test_ambiguous_diagnostic() -> None:
    row = lifecycle(
        states=("a", "b", "c"),
        transitions=[transition(dest="b"), transition(dest="c")],
        terminal=("b", "c"),
    )
    assert any("ambiguous" in message for message in diagnostics(row))
    named = lifecycle(
        states=("a", "b", "c"),
        transitions=[transition("left", dest="b"), transition("right", dest="c")],
        terminal=("b", "c"),
    )
    assert not [message for message in diagnostics(named) if "ambiguous" in message]
    model = fixture_model()
    model["lifecycles"][0]["transitions"].append(
        transition("go", "a", "b")
    )
    result = Interpreter(model).fire(
        graph(node("N", F="a")), {"name": "move", "subject": "N"}, "human"
    )
    assert result.verdict == "refused"
    assert result.refused_by == "ambiguous-dispatch"
    assert_shipped_diagnostics_silent("ambiguous")


@contract("grammar vocabulary mismatch is diagnosed beside the real match")
def test_vocabulary_diagnostic() -> None:
    grammar = {
        "WORK": {
            "fields": [{"name": "F", "options": ["a", "different"]}],
            "roles": [],
        }
    }
    row = lifecycle(transitions=[transition()])
    found = diagnostics(row, grammar)
    assert any("does not declare" in message for message in found)
    assert any("has no state" in message for message in found)
    assert all(diagnostics(item, GRAMMAR) == [] for item in SHIPPED["lifecycles"])


@contract("load validation rejects an unknown schema with known vocabulary")
def test_unknown_schema() -> None:
    model = empty_model()
    model["schema"] = "unknown"
    try:
        validate_model(model)
    except ModelError as error:
        assert "sdoc-semantics-model/1" in str(error)
    else:
        raise AssertionError("unknown schema loaded")
    try:
        validate_model({"schema": "sdoc-semantics-model/1"})
    except ModelError as error:
        assert "wrong shape" in str(error) and "model_version" in str(error)
    else:
        raise AssertionError("partial model loaded")


@contract("load validation rejects a bogus predicate operation")
def test_unknown_predicate_operation() -> None:
    model = fixture_model(
        gate={"name": "blocked", "sees": [], "predicate": {"op": "python"}}
    )
    try:
        validate_model(model)
    except ModelError as error:
        assert "unknown predicate operation" in str(error)
        assert "field_is" in str(error)
    else:
        raise AssertionError("bogus operation loaded")
    model = fixture_model()
    model["rules"] = [
        {
            "id": "BAD-RULE",
            "lifecycle": "L",
            "text": "fixture",
            "kind": "executable-python",
            "settled": False,
            "cites": [],
        }
    ]
    try:
        validate_model(model)
    except ModelError as error:
        assert "unknown kind" in str(error) and "open" in str(error)
    else:
        raise AssertionError("executable rule kind loaded")


@contract("load validation rejects an unknown transition state")
def test_unknown_state() -> None:
    model = fixture_model()
    model["lifecycles"][0]["transitions"][0]["to"] = "missing"
    try:
        validate_model(model)
    except ModelError as error:
        assert "missing" in str(error)
        assert "known states: a, b" in str(error)
    else:
        raise AssertionError("unknown state loaded")


@contract("gate lifecycle actor flow and transition references resolve")
def test_reference_validation() -> None:
    cases = []
    model = fixture_model()
    model["lifecycles"][0]["transitions"][0]["gates"] = ["missing"]
    cases.append((model, "known gates"))
    model = fixture_model()
    model["commands"][0]["lifecycle"] = "missing"
    cases.append((model, "known lifecycles"))
    model = fixture_model()
    model["commands"][0]["actor"] = "missing"
    cases.append((model, "known actors"))
    model = fixture_model()
    model["flows"] = [{"name": "F", "checkpoint": "missing", "steps": []}]
    cases.append((model, "wrong shape"))
    model = fixture_model()
    model["flows"] = [{"name": "F", "steps": [{"transition": "missing", "expected": "taken"}]}]
    cases.append((model, "known transitions"))
    model = fixture_model(
        gate={
            "name": "bad-direction",
            "sees": [],
            "predicate": {
                "op": "has_relation",
                "role": "Assumes",
                "direction": "sideways",
            },
        }
    )
    cases.append((model, "known directions"))
    for candidate, expected in cases:
        try:
            validate_model(candidate)
        except ModelError as error:
            assert expected in str(error), (expected, str(error))
        else:
            raise AssertionError(f"unresolved reference loaded: {expected}")


@contract("grammar validation rejects an unknown field and role")
def test_subject_validation() -> None:
    grammar = {
        "WORK": {
            "fields": [{"name": "F", "options": ["a", "b"]}],
            "roles": [{"role": "Assumes", "type": "Parent"}],
        }
    }
    model = fixture_model()
    model["lifecycles"][0]["subject"]["field"] = "MISSING"
    try:
        validate_model(model, grammar)
    except ModelError as error:
        assert "known fields" in str(error)
    else:
        raise AssertionError("unknown field loaded")
    model = fixture_model()
    model["lifecycles"][0]["subject"] = {
        "kind": "role",
        "role": "Missing",
        "field": "F",
    }
    try:
        validate_model(model, grammar)
    except ModelError as error:
        assert "known roles" in str(error)
    else:
        raise AssertionError("unknown role loaded")
    model = fixture_model(
        gate={
            "name": "bad-field",
            "sees": [],
            "predicate": {"op": "field_is", "field": "MISSING", "value": "x"},
        }
    )
    try:
        validate_model(model, grammar)
    except ModelError as error:
        assert "known fields" in str(error)
    else:
        raise AssertionError("unknown predicate field loaded")
    model = fixture_model()
    model["milestones"] = [
        {
            "name": "bad-subject",
            "subject": {"kind": "NOPE"},
            "achieved_when": "missing",
            "stale_when": "missing",
        }
    ]
    try:
        validate_model(model)
    except ModelError as error:
        assert "unknown subject kind" in str(error)
    else:
        raise AssertionError("unknown milestone subject loaded")
    model = fixture_model(
        gate={
            "name": "bad-sees-field",
            "sees": ["field:MISSING"],
            "predicate": {"op": "field_is", "field": "F", "value": "a"},
        }
    )
    try:
        validate_model(model, grammar)
    except ModelError as error:
        assert "known fields" in str(error)
    else:
        raise AssertionError("unknown sees field loaded")
    model = fixture_model()
    model["checkpoints"] = [{"name": "bad-sees-role", "sees": ["role:Missing"]}]
    try:
        validate_model(model, grammar)
    except ModelError as error:
        assert "known roles" in str(error)
    else:
        raise AssertionError("unknown sees role loaded")
    model["checkpoints"][0]["sees"] = ["relations"]
    try:
        validate_model(model, grammar)
    except ModelError as error:
        assert "known inputs" in str(error) and "git_base_ref" in str(error)
    else:
        raise AssertionError("malformed sees token loaded")


@contract("relation predicates reject second hops and invalid directions at load")
def test_predicate_traversal_limits() -> None:
    leaf = {"op": "field_is", "field": "F", "value": "a"}
    for outer in ("all_related", "any_related"):
        predicate = {"op": outer, "role": "Assumes", "empty": "fail", "predicate": leaf}
        model = fixture_model(gate={"name": "g", "sees": [], "predicate": predicate})
        validate_model(model)
        for inner in ("all_related", "any_related", "has_relation"):
            child = {"op": inner, "role": "Assumes"}
            if inner != "has_relation":
                child.update(empty="fail", predicate=leaf)
            predicate["predicate"] = {"op": "not", "predicate": {"op": "and", "predicates": [child]}}
            try:
                validate_model(model)
            except ModelError as error:
                assert "one hop" in str(error)
            else:
                raise AssertionError("second relation hop loaded")
        predicate["predicate"] = leaf
        predicate["direction"] = "sideways"
        try:
            validate_model(model)
        except ModelError as error:
            assert "known directions: in, out, either" in str(error)
        else:
            raise AssertionError("invalid relation direction loaded")
    model = fixture_model(gate={"name": "g", "sees": [], "predicate": {
        "op": "has_relation", "role": "Assumes", "direction": "either",
    }})
    validate_model(model)
    model["gates"][0]["predicate"]["direction"] = "sideways"
    try:
        validate_model(model)
    except ModelError as error:
        assert "known directions" in str(error)
    else:
        raise AssertionError("invalid has_relation direction loaded")


@contract("relation contract propagation must be a list")
def test_propagates_type() -> None:
    model = empty_model()
    row = {"role": "Assumes", "from_types": [], "to_types": [], "admits_cycles": False, "propagates": []}
    model["relation_contracts"] = [row]
    validate_model(model)
    for invalid in (False, "all", None, {}):
        row["propagates"] = invalid
        try:
            validate_model(model)
        except ModelError as error:
            assert "propagates must be a list" in str(error)
        else:
            raise AssertionError("non-list propagation loaded")


@contract("a refused gate leaves the graph byte-for-byte unchanged")
def test_transaction_refusal() -> None:
    gate = {
        "name": "ready",
        "sees": ["field:READY"],
        "predicate": {"op": "field_is", "field": "READY", "value": "yes"},
    }
    interpreter = Interpreter(fixture_model(gate=gate))
    original = graph(node("N", F="a", READY="no"))
    before = copy.deepcopy(original)
    result = interpreter.fire(original, {"name": "move", "subject": "N"}, "human")
    assert result.verdict == "refused" and result.refused_by == "ready"
    assert original == before
    allowed = graph(node("N", F="a", READY="yes"))
    result = interpreter.fire(allowed, {"name": "move", "subject": "N"}, "human")
    assert result.taken and allowed["nodes"]["N"]["fields"]["F"] == "b"
    invalid = fixture_model(command=False)
    invalid["operations"] = [
        {
            "name": "quiet-move",
            "subject": {"kind": "field", "field": "F"},
            "writes": [{"field": "F", "value": "b"}],
            "emits": [],
        }
    ]
    try:
        validate_model(invalid)
    except ModelError as error:
        assert "without moving state" in str(error)
    else:
        raise AssertionError("operation moved lifecycle state")
    assert SHIPPED["gates"] == []


@contract("ripple order and provenance are deterministic")
def test_ripple() -> None:
    model = empty_model()
    model["events"] = [
        {"name": "tick", "external": False},
        {"name": "pong", "external": False},
    ]
    model["operations"] = [
        {"name": "start", "subject": {"kind": "field", "field": "A"}, "writes": [], "emits": ["tick"]}
    ]
    model["lifecycles"] = [
        lifecycle("FIRST", "A", transitions=[transition("tick", emits=["pong"])]),
        lifecycle("SECOND", "B", states=("x", "y"), transitions=[transition("pong", "x", "y")], initial="x", terminal=("y",)),
    ]
    data = graph(node("Z", A="a", B="x"), node("A", A="a", B="x"))
    result = Interpreter(model).fire(data, {"name": "start", "subject": "Z"}, "human")
    assert result.taken
    assert [entry["subject"] for entry in result.log] == ["Z", "A", "Z", "A", "Z"]
    assert result.log[1]["event"] == "tick" and result.log[1]["emitter"] == "Z"
    assert result.log[-1]["transition"] == "SECOND:pong:x:y"
    assert SHIPPED["events"] == [] and SHIPPED["operations"] == []


@contract("provenance has one shape for operations transitions and gate refusals")
def test_provenance_shape() -> None:
    gate = {"name": "ready", "sees": ["field:READY"], "predicate": {
        "op": "field_is", "field": "READY", "value": "yes",
    }}
    model = fixture_model(gate=gate)
    model["events"] = [{"name": "go", "external": False}]
    model["operations"] = [{
        "name": "start", "subject": {"kind": "field", "field": "F"},
        "writes": [], "emits": ["go"],
    }]
    expected_keys = {"subject", "transition", "event", "emitter", "gate", "rule", "verdict", "operation"}
    for name in ("move", "start"):
        for ready in ("yes", "no"):
            result = Interpreter(model).fire(
                graph(node("N", F="a", READY=ready)), {"name": name, "subject": "N"}, "human"
            )
            assert result.taken == (ready == "yes")
            assert len(result.log) == (2 if name == "start" else 1)
            for step in result.log:
                assert set(step) == expected_keys
                assert isinstance(step["gate"], list)
                assert all(isinstance(gate_name, str) for gate_name in step["gate"])
                for key in expected_keys - {"gate"}:
                    assert step[key] is None or isinstance(step[key], str)
            assert result.log[-1]["gate"] == ["ready"]
            assert result.log[-1]["operation"] is None
            if name == "start":
                assert result.log[0]["gate"] == [] and result.log[0]["operation"] == "start"


@contract("a cyclic ripple refuses at its first repeat with the bound as backstop")
def test_ripple_bound() -> None:
    model = empty_model()
    model["events"] = [
        {"name": "forward", "external": False},
        {"name": "back", "external": False},
    ]
    model["operations"] = [
        {"name": "start", "subject": {"kind": "field", "field": "F"}, "writes": [], "emits": ["forward"]}
    ]
    model["lifecycles"] = [
        lifecycle(
            transitions=[
                transition("forward", "a", "b", emits=["back"]),
                transition("back", "b", "a", emits=["forward"]),
            ]
        )
    ]
    data = graph(node("N", F="a"))
    before = copy.deepcopy(data)
    result = Interpreter(model, step_bound=24).fire(
        data, {"name": "start", "subject": "N"}, "human"
    )
    assert result.verdict == "refused" and result.refused_by == "cycle"
    assert len(result.log) == 3  # start, forward, back; refuse the next forward
    assert "L:forward:a:b" in result.reason
    assert data == before
    bounded = Interpreter(model, step_bound=2).fire(
        data, {"name": "start", "subject": "N"}, "human"
    )
    assert bounded.refused_by == "step-bound" and len(bounded.log) == 2
    assert data == before


@contract("edge subjects have stable keys and mutate only the selected staged edge")
def test_edge_subjects() -> None:
    from sdoc_semantics.engine import _matching_subjects

    model = fixture_model()
    subject = {"kind": "role", "role": "Assumes", "field": "F"}
    model["lifecycles"][0]["subject"] = subject
    chosen = {"role": "Assumes", "source": "A", "target": "B", "fields": {"F": "a"}}
    untouched = {"role": "Assumes", "source": "X", "target": "Y"}
    data = graph(edges=[copy.deepcopy(chosen), copy.deepcopy(untouched)])
    before = copy.deepcopy(data)
    keys = [row["uid"] for row in _matching_subjects(data, subject)]
    assert data == before and keys == ["A:Assumes:B", "X:Assumes:Y"]
    inserted = {"role": "Assumes", "source": "0", "target": "1"}
    data["edges"].insert(0, inserted)
    assert [row["uid"] for row in _matching_subjects(data, subject)] == [
        "0:Assumes:1", *keys,
    ]
    result = Interpreter(model).fire(data, {"name": "move", "subject": keys[0]}, "human")
    assert result.taken and result.log[0]["subject"] == keys[0]
    assert data["edges"][1] == {**chosen, "fields": {"F": "b"}}
    assert data["edges"][0] == inserted and data["edges"][2] == untouched
    assert all("uid" not in edge for edge in data["edges"])
    data["edges"].append(copy.deepcopy(data["edges"][1]))
    before = copy.deepcopy(data)
    refused = Interpreter(model).fire(data, {"name": "move", "subject": keys[0]}, "human")
    assert refused.refused_by == "subject" and "duplicate edge subject" in refused.reason
    assert data == before


@contract("relation contracts report role endpoint and cycle violations")
def test_relation_contracts() -> None:
    model = empty_model()
    model["relation_contracts"] = [
        {
            "role": "Assumes",
            "from_types": ["WORK"],
            "to_types": ["REQUIREMENT"],
            "admits_cycles": False,
            "propagates": [],
        }
    ]
    interpreter = Interpreter(model)
    valid = graph(
        node("A", "WORK"),
        node("B", "REQUIREMENT"),
        edges=[{"role": "Assumes", "source": "A", "target": "B"}],
    )
    assert interpreter.check(valid) == []
    invalid = graph(
        node("A", "REQUIREMENT"),
        node("B", "WORK"),
        node("C", "REQUIREMENT"),
        node("D", "WORK"),
        edges=[
            {"role": "Assumes", "source": "A", "target": "B"},
            {"role": "Assumes", "source": "B", "target": "A"},
            {"role": "Assumes", "source": "C", "target": "D"},
            {"role": "Assumes", "source": "D", "target": "C"},
            {"role": "Unknown", "source": "A", "target": "B"},
        ],
    )
    found = interpreter.check(invalid)
    assert any("source type" in message for message in found)
    assert any("target type" in message for message in found)
    assert any("no relation contract" in message for message in found)
    assert [message for message in found if "admits no cycles:" in message] == [
        "role 'Assumes' admits no cycles: A -> B -> A",
    ]
    assert SHIPPED["relation_contracts"] == []


@contract("cycle diagnostics return one witness per role and report scan exhaustion")
def test_cycle_scan_bound() -> None:
    from sdoc_semantics.engine import _simple_cycles

    chain = {str(index): [str(index + 1)] for index in range(1200)}
    assert _simple_cycles(chain) == []  # deeper than recursive DFS can safely walk
    model = empty_model()
    model["relation_contracts"] = [
        {"role": role, "from_types": ["WORK"], "to_types": ["WORK"],
         "admits_cycles": False, "propagates": []}
        for role in ("Assumes", "Cites")
    ]
    data = graph(node("A"), node("B"), node("C"), edges=[
        {"role": role, "source": source, "target": target}
        for role in ("Assumes", "Cites")
        for source, target in (("A", "B"), ("B", "A"), ("A", "C"), ("C", "A"))
    ])
    found = Interpreter(model).check(data)
    assert len(found) == 2 and all("admits no cycles" in message for message in found)
    assert "Assumes" in found[0] and "Cites" in found[1]
    exhausted = Interpreter(model, cycle_bound=1).check(data)
    assert len(exhausted) == 2 and all("cycle scan exceeded step bound 1" in message for message in exhausted)
    assert Interpreter(SHIPPED, cycle_bound=1).check(graph()) == []


@contract("gate placement derives checkpoint visibility in list order")
def test_gate_placement() -> None:
    model = empty_model()
    model["actors"] = [{"name": "human"}]
    model["gates"] = [
        {
            "name": "g",
            "sees": ["field:F", "actor"],
            "predicate": {"op": "actor_in", "actors": ["human"]},
        }
    ]
    model["checkpoints"] = [
        {"name": "too-early", "sees": ["field:F"]},
        {
            "name": "ready",
            "sees": ["field:F", "actor", "role:Assumes", "git_base_ref"],
        },
    ]
    grammar = {
        "WORK": {
            "fields": [{"name": "F", "options": []}],
            "roles": [{"role": "Assumes", "type": "Parent"}],
        }
    }
    validate_model(model, grammar)
    assert gate_placement(model) == [{"gate": "g", "checkpoints": ["ready"]}]
    assert gate_placement(SHIPPED) == []


@contract("flows remain data and their references validate")
def test_flows() -> None:
    model = fixture_model()
    reference = "L:go:a:b"
    model["flows"] = [
        {"name": "happy", "steps": [{"transition": reference, "expected": "taken"}]}
    ]
    validate_model(model)
    assert model["flows"][0]["steps"][0]["transition"] == reference
    model["flows"][0]["steps"][0]["expected"] = "exploded"
    try:
        validate_model(model)
    except ModelError as error:
        assert "known outcomes" in str(error)
    else:
        raise AssertionError("unknown flow outcome loaded")
    refused = fixture_model(
        gate={
            "name": "stop",
            "sees": ["field:F"],
            "predicate": {"op": "field_is", "field": "F", "value": "a"},
        }
    )
    refused["flows"] = [
        {
            "name": "refusal",
            "steps": [
                {
                    "transition": reference,
                    "expected": "refused",
                    "refused_by": "stop",
                }
            ],
        }
    ]
    validate_model(refused)
    refused["flows"][0]["steps"][0]["expected"] = "taken"
    try:
        validate_model(refused)
    except ModelError as error:
        assert "taken but names a refusing gate" in str(error)
    else:
        raise AssertionError("contradictory flow outcome loaded")
    assert SHIPPED["flows"] == []


@contract("payload v2 keys are exact and additions stay ordered")
def test_payload_keys() -> None:
    assert tuple(SHIPPED_PAYLOAD) == PAYLOAD_KEYS
    assert set(SHIPPED_PAYLOAD) == set(PAYLOAD_KEYS)
    assert SHIPPED_PAYLOAD["schema"] == SCHEMA


@contract("payload and Mermaid rendering validate once without reloading the model")
def test_single_payload_validation() -> None:
    from sdoc_semantics import cli, engine

    with mock.patch.object(engine, "validate_model", wraps=engine.validate_model) as validate:
        data = build_payload(GRAMMAR)
        assert validate.call_count == 1
        diagram = cli.render_mermaid(data, "STATUS")
        assert diagram == "%% STATUS\n" + mermaid(SHIPPED["lifecycles"][0]) + "\n\n"
        assert validate.call_count == 1
    with mock.patch.object(engine, "validate_model", wraps=engine.validate_model) as validate:
        assert payload(SHIPPED, GRAMMAR) == data
        assert validate.call_count == 1


@contract("presentation order survives model loading and payload emission")
def test_presentation_order() -> None:
    assert [row["name"] for row in SHIPPED["lifecycles"]] == [
        "STATUS",
        "AUTHORED_BY",
    ]
    assert list(SHIPPED_PAYLOAD["machines"]) == ["STATUS", "AUTHORED_BY"]
    assert [row["name"] for row in SHIPPED_PAYLOAD["machines"]["STATUS"]["states"]] == [
        "open",
        "accepted",
        "rejected",
        "superseded",
    ]
    assert [row["name"] for row in SHIPPED_PAYLOAD["machines"]["AUTHORED_BY"]["states"]] == [
        "llm",
        "human-adopted",
        "human",
    ]
    assert all("rules" not in lifecycle for lifecycle in SHIPPED["lifecycles"])
    model = empty_model()
    model["lifecycles"] = [
        lifecycle(
            "ONE_F",
            "F",
            transitions=[transition()],
            subject={"kind": "element", "tag": "ONE", "field": "F"},
        ),
        lifecycle(
            "TWO_F",
            "F",
            transitions=[transition()],
            subject={"kind": "element", "tag": "TWO", "field": "F"},
        ),
    ]
    grammar = {
        tag: {
            "fields": [{"name": "F", "options": ["a", "b"]}],
            "roles": [],
        }
        for tag in ("ONE", "TWO")
    }
    emitted = payload(model, grammar)
    assert list(emitted["machines"]) == ["ONE_F", "TWO_F"]
    assert emitted["by_type"] == {"ONE": ["ONE_F"], "TWO": ["TWO_F"]}
    assert all(not machine["diagnostics"] for machine in emitted["machines"].values())


@contract("lifecycle notes preserve the transcription and are optional strings")
def test_lifecycle_notes() -> None:
    assert [row["note"] for row in SHIPPED["lifecycles"]] == [
        "Branching on purpose: two terminal states, and one rule no machine can hold.",
        "Shape is settled by an accepted DECISION; the actor is not.",
    ]
    model = fixture_model()
    validate_model(model)  # no note is valid
    model["lifecycles"][0]["note"] = "fixture"
    validate_model(model)
    model["lifecycles"][0]["note"] = False
    try:
        validate_model(model)
    except ModelError as error:
        assert "note must be a string" in str(error)
    else:
        raise AssertionError("non-string lifecycle note loaded")


@contract("rule ownership is explicit and lifecycle references resolve")
def test_rule_lifecycle() -> None:
    model = fixture_model()
    grammar = {"WORK": {"fields": [{"name": "F", "options": ["a", "b"]}], "roles": []}}
    rule = {
        "id": "OPAQUE", "text": "fixture", "kind": "open",
        "settled": False, "cites": [], "lifecycle": "L",
    }
    model["rules"] = [rule]
    validate_model(model)
    assert payload(model, grammar)["machines"]["L"]["rules"] == [
        {key: value for key, value in rule.items() if key != "lifecycle"}
    ]
    rule["lifecycle"] = None
    validate_model(model)
    assert payload(model, grammar)["machines"]["L"]["rules"] == []
    rule["lifecycle"] = "missing"
    try:
        validate_model(model)
    except ModelError as error:
        assert "known lifecycles: L" in str(error)
    else:
        raise AssertionError("unknown rule lifecycle loaded")


@contract("the shipped lifecycle rows exactly match the v1 baseline")
def test_shipped_rows() -> None:
    assert SHIPPED_PAYLOAD["machines"] == EXPECTED_MACHINES


@contract("mermaid uses safe identifiers and carries gate names")
def test_mermaid() -> None:
    row = lifecycle(
        states=("in-progress", "done"),
        transitions=[transition("advance", "in-progress", "done", gates=["policy-gate"])],
        initial="in-progress",
        terminal=("done",),
    )
    drawing = mermaid(row)
    assert "state_0 --> state_1 : advance [policy-gate]" in drawing
    assert "in-progress -->" not in drawing
    assert 'state "in-progress" as state_0' in drawing


@contract("the CLI imports and renders with an isolated standard-library Python")
def test_cli_stdlib() -> None:
    environment = {
        "PATH": os.environ.get("PATH", ""),
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    completed = subprocess.run(
        [
            sys.executable,
            "-I",
            str(REPO_ROOT / "dev" / "scripts" / "sdoc_semantics" / "__main__.py"),
            "--root",
            str(REPO_ROOT),
            "STATUS",
        ],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )
    assert completed.returncode == 0, completed.stderr
    assert "STATUS   [sdoc-semantics/2]" in completed.stdout


@contract("non-semantics verbs remain available without the semantics package")
def test_scribe_isolation() -> None:
    with tempfile.TemporaryDirectory() as directory:
        scripts = Path(directory) / "scripts"
        shutil.copytree(
            REPO_ROOT / "dev" / "scripts", scripts,
            ignore=shutil.ignore_patterns("sdoc_semantics", "__pycache__"),
        )
        probe = """
import contextlib
import importlib.util
import io
import sys
sys.path.insert(0, sys.argv[1])
assert importlib.util.find_spec("sdoc_semantics") is None
import scribe_cmd
from scribe_grammar import parse_sgra
grammar = parse_sgra(scribe_cmd.Path(sys.argv[2]) / "docs/sdoc/grammar.sgra")
parser = scribe_cmd.build_parser(grammar, None, None)
verbs = next(action.choices for action in parser._actions if isinstance(action.choices, dict))
for verb in verbs:
    if verb != "semantics":
        with contextlib.redirect_stdout(io.StringIO()) as output:
            try:
                parser.parse_args([verb, "--help"])
            except SystemExit as exc:
                assert exc.code == 0, verb
        assert "usage: scribe" in output.getvalue(), verb
        print(verb)
args = parser.parse_args(["semantics"])
with contextlib.redirect_stderr(io.StringIO()) as error:
    assert scribe_cmd.run_semantics(args, grammar) == 1
assert "semantics engine is unavailable" in error.getvalue()
"""
        result = subprocess.run(
            [sys.executable, "-I", "-c", probe, str(scripts), str(REPO_ROOT)],
            capture_output=True, text=True, check=False,
        )
        assert result.returncode == 0, result.stderr
        assert set(result.stdout.splitlines()) == {
            "check", "delete", "list", "move", "new", "relate", "set", "show", "unrelate",
        }


@contract("load_model reads and validates a JSON fixture")
def test_load_model() -> None:
    model = fixture_model()
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "model.json"
        path.write_text(json.dumps(model))
        assert load_model(path) == model

    class Field:
        def __init__(self, value):
            self.value = value

        def get_text_value(self):
            return self.value

    first = SimpleNamespace(
        reserved_uid="A",
        node_type="WORK",
        ordered_fields_lookup={"AUTHORED_BY": [Field("llm")]},
        relations=[SimpleNamespace(ref_uid="B", role="Assumes")],
    )
    second = SimpleNamespace(
        reserved_uid="B",
        node_type="REQUIREMENT",
        ordered_fields_lookup={"AUTHORED_BY": [Field("human")]},
        relations=[],
    )
    loaded = SimpleNamespace(iter_nodes=lambda: iter((first, second)))
    assert adapt_graph(loaded) == graph(
        node("A", "WORK", AUTHORED_BY="llm"),
        node("B", "REQUIREMENT", AUTHORED_BY="human"),
        edges=[{"role": "Assumes", "source": "A", "target": "B"}],
    )


def main() -> int:
    tests = [
        value
        for name, value in globals().items()
        if name.startswith("test_") and hasattr(value, "contract_name")
    ]
    for test in tests:
        test()
    print(f"{len(PASSED)} semantics contract(s) passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
