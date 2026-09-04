#!/usr/bin/env python3
# cspell:ignore PYTHONDONTWRITEBYTECODE sdoc sgra
"""Executable contracts for the standard-library semantics interpreter."""

from __future__ import annotations

import copy
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path
from types import SimpleNamespace

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
    node("A", "WORK", DEPTH="implemented", FLAG="yes"),
    node("B", "REQUIREMENT", DEPTH="verified", FLAG="yes"),
    node("C", "EVIDENCE", DEPTH="sketch", FLAG="no"),
    edges=(
        {"role": "Assumes", "source": "A", "target": "B"},
        {"role": "Assumes", "source": "A", "target": "C"},
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
        {"op": "field_at_least", "field": "DEPTH", "value": "needs-spike"},
        PREDICATE_NODE,
        PREDICATE_GRAPH,
        "human",
        SHIPPED,
    )
    assert not evaluate(
        {"op": "field_at_least", "field": "DEPTH", "value": "verified"},
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


@contract("a refused gate leaves the graph byte-for-byte unchanged")
def test_transaction_refusal() -> None:
    gate = {
        "name": "ready",
        "sees": ["READY"],
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


@contract("a cyclic ripple refuses by the bound without committing")
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
    result = Interpreter(model, step_bound=4).fire(
        data, {"name": "start", "subject": "N"}, "human"
    )
    assert result.verdict == "refused" and result.refused_by == "step-bound"
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
        "role 'Assumes' admits no cycles: C -> D -> C",
    ]
    assert SHIPPED["relation_contracts"] == []


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
        {"name": "ready", "sees": ["field:F", "actor", "relations"]},
    ]
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


@contract("presentation order survives model loading and payload emission")
def test_presentation_order() -> None:
    assert [row["name"] for row in SHIPPED["lifecycles"]] == [
        "DEPTH",
        "STATUS",
        "AUTHORED_BY",
    ]
    assert list(SHIPPED_PAYLOAD["machines"]) == ["DEPTH", "STATUS", "AUTHORED_BY"]
    assert [row["name"] for row in SHIPPED_PAYLOAD["machines"]["DEPTH"]["states"]] == [
        "sketch",
        "needs-design",
        "needs-spike",
        "interface-settled",
        "implemented",
        "verified",
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


@contract("the shipped lifecycle rows exactly match the v1 baseline")
def test_shipped_rows() -> None:
    assert SHIPPED_PAYLOAD["machines"] == EXPECTED_MACHINES


@contract("mermaid uses safe identifiers and carries gate names")
def test_mermaid() -> None:
    row = lifecycle(
        states=("needs-design", "implemented"),
        transitions=[transition("advance", "needs-design", "implemented", gates=["ready-gate"])],
        initial="needs-design",
        terminal=("implemented",),
    )
    drawing = mermaid(row)
    assert "state_0 --> state_1 : advance [ready-gate]" in drawing
    assert "needs-design -->" not in drawing
    assert 'state "needs-design" as state_0' in drawing


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
            "DEPTH",
        ],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )
    assert completed.returncode == 0, completed.stderr
    assert "DEPTH   [sdoc-semantics/2]" in completed.stdout


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
        ordered_fields_lookup={"DEPTH": [Field("sketch")]},
        relations=[SimpleNamespace(ref_uid="B", role="Assumes")],
    )
    second = SimpleNamespace(
        reserved_uid="B",
        node_type="REQUIREMENT",
        ordered_fields_lookup={"DEPTH": [Field("verified")]},
        relations=[],
    )
    loaded = SimpleNamespace(iter_nodes=lambda: iter((first, second)))
    assert adapt_graph(loaded) == graph(
        node("A", "WORK", DEPTH="sketch"),
        node("B", "REQUIREMENT", DEPTH="verified"),
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
