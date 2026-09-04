# cspell:ignore popleft sdoc sgra
"""Standard-library interpreter for the data in ``model.json``.

The model contains the rules. This module contains only fixed mechanics for
validating, querying, dispatching, checking and rendering that data. ``fire``
works on a staged graph and commits only after every ripple succeeds; the
scribe daemon does not call it yet.
"""

from __future__ import annotations

import copy
import json
from collections import deque
from pathlib import Path
from typing import Any, Callable, Iterable, Mapping, MutableMapping

from .declare import FireResult, ModelError

MODEL_SCHEMA = "sdoc-semantics-model/1"
SCHEMA = "sdoc-semantics/2"
MODEL_PATH = Path(__file__).with_name("model.json")
PREDICATE_OPERATIONS = (
    "actor_in",
    "all_related",
    "and",
    "any_related",
    "field_at_least",
    "field_is",
    "has_relation",
    "not",
    "or",
)
PAYLOAD_KEYS = (
    "schema",
    "machines",
    "by_type",
    "gates",
    "relation_contracts",
    "actors",
    "commands",
    "events",
    "operations",
    "milestones",
    "checkpoints",
    "flows",
    "gate_placement",
)


def _names(rows: Iterable[Mapping[str, Any]]) -> list[str]:
    return [str(row.get("name")) for row in rows if row.get("name") is not None]


def _known(label: str, values: Iterable[str]) -> str:
    return f"known {label}: {', '.join(values) or '(none)'}"


def _grammar_fields(grammar: Mapping[str, Any]) -> set[str]:
    return {
        field["name"]
        for element in grammar.values()
        for field in element.get("fields", [])
    }


def _grammar_roles(grammar: Mapping[str, Any]) -> set[str]:
    return {
        role["role"]
        for element in grammar.values()
        for role in element.get("roles", [])
        if role.get("role")
    }


def _require_reference(
    value: str, declared: Iterable[str], label: str, location: str
) -> None:
    choices = list(declared)
    if value not in choices:
        raise ModelError(
            f"{location} names unknown {label} {value!r}; {_known(label + 's', choices)}"
        )


def _validate_predicate(predicate: Any, location: str) -> None:
    if not isinstance(predicate, dict):
        raise ModelError(f"{location} predicate must be an object")
    operation = predicate.get("op")
    if operation not in PREDICATE_OPERATIONS:
        raise ModelError(
            f"{location} names unknown predicate operation {operation!r}; "
            f"{_known('operations', PREDICATE_OPERATIONS)}"
        )
    if operation in ("and", "or"):
        for index, child in enumerate(predicate.get("predicates", [])):
            _validate_predicate(child, f"{location}.{operation}[{index}]")
    elif operation == "not":
        _validate_predicate(predicate.get("predicate"), f"{location}.not")
    elif operation in ("all_related", "any_related"):
        if predicate.get("empty") not in ("pass", "fail"):
            raise ModelError(
                f"{location}.{operation} must say whether empty is 'pass' or 'fail'"
            )
        _validate_predicate(
            predicate.get("predicate"), f"{location}.{operation}.predicate"
        )


def _validate_predicate_references(
    predicate: Mapping[str, Any],
    model: Mapping[str, Any],
    grammar: Mapping[str, Any] | None,
    location: str,
) -> None:
    operation = predicate["op"]
    if operation in ("and", "or"):
        for index, child in enumerate(predicate.get("predicates", [])):
            _validate_predicate_references(
                child, model, grammar, f"{location}.{operation}[{index}]"
            )
    elif operation == "not":
        _validate_predicate_references(
            predicate["predicate"], model, grammar, f"{location}.not"
        )
    elif operation in ("all_related", "any_related"):
        if grammar is not None:
            _require_reference(
                predicate.get("role"),
                _grammar_roles(grammar),
                "role",
                f"{location}.{operation}",
            )
        _validate_predicate_references(
            predicate["predicate"],
            model,
            grammar,
            f"{location}.{operation}.predicate",
        )
    elif operation == "has_relation" and grammar is not None:
        _require_reference(
            predicate.get("role"),
            _grammar_roles(grammar),
            "role",
            f"{location}.has_relation",
        )
    elif operation == "actor_in":
        declared = _names(model.get("actors", []))
        for actor in predicate.get("actors", predicate.get("values", [])):
            _require_reference(actor, declared, "actor", f"{location}.actor_in")
    elif operation == "field_at_least":
        field = predicate.get("field")
        lifecycles = [
            row
            for row in model.get("lifecycles", [])
            if row.get("subject", {}).get("field") == field
        ]
        if not lifecycles:
            raise ModelError(
                f"{location}.field_at_least names unknown lifecycle field {field!r}; "
                f"{_known('fields', [row.get('subject', {}).get('field') for row in model.get('lifecycles', [])])}"
            )
        states = _names(lifecycles[0].get("states", []))
        _require_reference(
            predicate.get("value"), states, "state", f"{location}.field_at_least"
        )


def _validate_subject(
    subject: Mapping[str, Any],
    grammar: Mapping[str, Any] | None,
    location: str,
) -> None:
    kind = subject.get("kind")
    if kind not in ("element", "field", "role"):
        raise ModelError(
            f"{location} has unknown subject kind {kind!r}; "
            "known subject kinds: element, field, role"
        )
    if grammar is None:
        return
    _require_reference(subject.get("field"), _grammar_fields(grammar), "field", location)
    if kind == "element":
        _require_reference(subject.get("tag"), grammar.keys(), "element", location)
    if kind == "role":
        _require_reference(subject.get("role"), _grammar_roles(grammar), "role", location)


def transition_reference(lifecycle: str, transition: Mapping[str, Any]) -> str:
    return ":".join(
        (
            lifecycle,
            str(transition.get("trigger")),
            str(transition.get("from")),
            str(transition.get("to")),
        )
    )


def validate_model(
    model: Mapping[str, Any], grammar: Mapping[str, Any] | None = None
) -> None:
    """Refuse unresolved vocabulary while preserving list presentation order."""
    if model.get("schema") != MODEL_SCHEMA:
        raise ModelError(
            f"unknown model schema {model.get('schema')!r}; known schemas: {MODEL_SCHEMA}"
        )

    lifecycles = model.get("lifecycles", [])
    lifecycle_names = _names(lifecycles)
    gate_names = _names(model.get("gates", []))
    actor_names = _names(model.get("actors", []))
    event_names = _names(model.get("events", []))
    checkpoint_names = _names(model.get("checkpoints", []))
    named_collections = (
        ("lifecycle", lifecycle_names),
        ("gate", gate_names),
        ("actor", actor_names),
        ("event", event_names),
        ("checkpoint", checkpoint_names),
        ("command", _names(model.get("commands", []))),
        ("operation", _names(model.get("operations", []))),
    )
    for label, values in named_collections:
        if len(values) != len(set(values)):
            raise ModelError(f"duplicate {label} name; {_known(label + 's', values)}")

    grammar_roles = _grammar_roles(grammar or {})
    grammar_types = list((grammar or {}).keys())
    for lifecycle in lifecycles:
        name = lifecycle["name"]
        states = _names(lifecycle.get("states", []))
        if len(states) != len(set(states)):
            raise ModelError(
                f"lifecycle {name!r} has duplicate states; {_known('states', states)}"
            )
        initial = lifecycle.get("initial")
        if initial is not None:
            _require_reference(initial, states, "state", f"lifecycle {name!r} initial")
        for terminal in lifecycle.get("terminal", []):
            _require_reference(
                terminal, states, "state", f"lifecycle {name!r} terminal"
            )
        for index, transition in enumerate(lifecycle.get("transitions", [])):
            location = f"lifecycle {name!r} transition {index}"
            _require_reference(transition.get("from"), states, "state", location)
            _require_reference(transition.get("to"), states, "state", location)
            for gate in transition.get("gates", []):
                _require_reference(gate, gate_names, "gate", location)
            for event in transition.get("emits", []):
                _require_reference(event, event_names, "event", location)

        _validate_subject(lifecycle.get("subject", {}), grammar, f"lifecycle {name!r}")

    for gate in model.get("gates", []):
        _validate_predicate(gate.get("predicate"), f"gate {gate['name']!r}")
        _validate_predicate_references(
            gate["predicate"], model, grammar, f"gate {gate['name']!r}"
        )

    for command in model.get("commands", []):
        location = f"command {command['name']!r}"
        lifecycle_name = command.get("lifecycle")
        _require_reference(lifecycle_name, lifecycle_names, "lifecycle", location)
        if command.get("actor") is not None:
            _require_reference(command["actor"], actor_names, "actor", location)
        known = [
            transition_reference(lifecycle["name"], transition)
            for lifecycle in lifecycles
            if lifecycle["name"] == lifecycle_name
            for transition in lifecycle.get("transitions", [])
        ]
        matching = [
            reference
            for reference in known
            if reference.split(":", 2)[1] == command.get("trigger")
        ]
        if not matching:
            raise ModelError(
                f"{location} names unknown transition trigger {command.get('trigger')!r}; "
                f"{_known('transitions', known)}"
            )

    for operation in model.get("operations", []):
        _validate_subject(
            operation.get("subject", {}), grammar, f"operation {operation['name']!r}"
        )
        for event in operation.get("emits", []):
            _require_reference(
                event, event_names, "event", f"operation {operation['name']!r}"
            )
    if grammar is not None:
        for contract in model.get("relation_contracts", []):
            _require_reference(
                contract.get("role"),
                grammar_roles,
                "role",
                f"relation contract {contract.get('role')!r}",
            )
            for key in ("from_types", "to_types"):
                for tag in contract.get(key, []):
                    _require_reference(
                        tag,
                        grammar_types,
                        "element",
                        f"relation contract {contract['role']!r} {key}",
                    )
    for milestone in model.get("milestones", []):
        for key in ("achieved_when", "stale_when"):
            _require_reference(
                milestone.get(key),
                gate_names,
                "gate",
                f"milestone {milestone['name']!r}",
            )

    all_transition_refs = [
        transition_reference(lifecycle["name"], transition)
        for lifecycle in lifecycles
        for transition in lifecycle.get("transitions", [])
    ]
    for flow in model.get("flows", []):
        for index, step in enumerate(flow.get("steps", [])):
            _require_reference(
                step.get("transition"),
                all_transition_refs,
                "transition",
                f"flow {flow['name']!r} step {index}",
            )
            refused_by = step.get("refused_by")
            if refused_by is not None:
                _require_reference(
                    refused_by,
                    gate_names,
                    "gate",
                    f"flow {flow['name']!r} step {index}",
                )
        checkpoint = flow.get("checkpoint")
        if checkpoint is not None:
            _require_reference(
                checkpoint,
                checkpoint_names,
                "checkpoint",
                f"flow {flow['name']!r}",
            )


def load_model(
    path: str | Path = MODEL_PATH, grammar: Mapping[str, Any] | None = None
) -> dict[str, Any]:
    """Load one JSON document and validate all of its references."""
    with Path(path).open(encoding="utf-8") as stream:
        model = json.load(stream)
    validate_model(model, grammar)
    return model


def applies_to(subject: Mapping[str, Any], grammar: Mapping[str, Any]) -> list[str]:
    """Return grammar types matched by a lifecycle subject, in grammar order."""
    kind = subject["kind"]
    if kind == "element":
        return [subject["tag"]]
    if kind == "role":
        role = subject["role"]
        return [
            tag
            for tag, element in grammar.items()
            if any(entry.get("role") == role for entry in element.get("roles", []))
        ]
    field = subject["field"]
    return [
        tag
        for tag, element in grammar.items()
        if any(entry.get("name") == field for entry in element.get("fields", []))
    ]


def grammar_options(field: str, grammar: Mapping[str, Any]) -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    for tag, element in grammar.items():
        for entry in element.get("fields", []):
            if entry.get("name") == field:
                out[tag] = list(entry.get("options", []))
    return out


def _reachable(lifecycle: Mapping[str, Any]) -> set[str]:
    initial = lifecycle.get("initial")
    reached = {initial} if initial is not None else set()
    frontier = [initial] if initial is not None else []
    while frontier:
        source = frontier.pop()
        for transition in lifecycle.get("transitions", []):
            target = transition["to"]
            if transition["from"] == source and target not in reached:
                reached.add(target)
                frontier.append(target)
    return reached


def diagnostics(
    lifecycle: Mapping[str, Any], grammar: Mapping[str, Any] | None = None
) -> list[str]:
    """Report model-only topology and grammar-vocabulary defects."""
    name = lifecycle["name"]
    states = _names(lifecycle.get("states", []))
    found: list[str] = []
    if lifecycle.get("initial") is None:
        found.append(f"{name}: no initial state")
    else:
        for state in states:
            if state not in _reachable(lifecycle):
                found.append(
                    f"{name}: state {state!r} is unreachable from {lifecycle['initial']!r}"
                )
    if not lifecycle.get("terminal"):
        found.append(f"{name}: no terminal state")
    seen: dict[tuple[str, str], str] = {}
    for transition in lifecycle.get("transitions", []):
        key = (transition["from"], transition["trigger"])
        if key in seen:
            found.append(
                f"{name}: trigger {transition['trigger']!r} fires from "
                f"{transition['from']!r} to both {seen[key]!r} and "
                f"{transition['to']!r} -- ambiguous"
            )
        else:
            seen[key] = transition["to"]
    if grammar is not None:
        declared = set(states)
        field = lifecycle["subject"]["field"]
        for tag, options in grammar_options(field, grammar).items():
            extra = declared - set(options)
            missing = set(options) - declared
            if extra:
                found.append(
                    f"{name}: {tag} does not declare {sorted(extra)} -- "
                    f"the grammar knows {options}"
                )
            if missing:
                found.append(
                    f"{name}: {tag} declares {sorted(missing)}, which this "
                    "lifecycle has no state for"
                )
    return found


def machine_payload(lifecycle: Mapping[str, Any], grammar: Mapping[str, Any]) -> dict:
    """Render one lifecycle in the stable v1-compatible machine shape."""
    return {
        "field": lifecycle["subject"]["field"],
        "applies_to": applies_to(lifecycle["subject"], grammar),
        "initial": lifecycle.get("initial"),
        "terminal": list(lifecycle.get("terminal", [])),
        "states": [
            {key: state[key] for key in ("name", "label", "note") if state.get(key)}
            for state in lifecycle.get("states", [])
        ],
        "transitions": [
            {
                "trigger": transition["trigger"],
                "source": transition["from"],
                "dest": transition["to"],
                "conditions": list(transition.get("gates", [])),
                "unless": [],
                "rule_text": transition.get("rule_text", ""),
                "settled": bool(transition.get("settled", False)),
            }
            for transition in lifecycle.get("transitions", [])
        ],
        "rules": [dict(rule) for rule in lifecycle.get("rules", [])],
        "diagnostics": diagnostics(lifecycle, grammar),
    }


def gate_placement(model: Mapping[str, Any]) -> list[dict[str, Any]]:
    """Derive checkpoints where each gate's declared inputs are visible."""
    checkpoints = model.get("checkpoints", [])
    return [
        {
            "gate": gate["name"],
            "checkpoints": [
                checkpoint["name"]
                for checkpoint in checkpoints
                if set(gate.get("sees", [])) <= set(checkpoint.get("sees", []))
            ],
        }
        for gate in model.get("gates", [])
    ]


def payload(model: Mapping[str, Any], grammar: Mapping[str, Any]) -> dict:
    """Build the exact ``sdoc-semantics/2`` board contract."""
    validate_model(model, grammar)
    machines: dict[str, dict] = {}
    for lifecycle in model.get("lifecycles", []):
        machines[lifecycle["subject"]["field"]] = machine_payload(lifecycle, grammar)
    by_type: dict[str, list[str]] = {tag: [] for tag in grammar}
    for field, machine in machines.items():
        for tag in machine["applies_to"]:
            by_type[tag].append(field)
    values = {
        "schema": SCHEMA,
        "machines": machines,
        "by_type": by_type,
        "gates": copy.deepcopy(model.get("gates", [])),
        "relation_contracts": copy.deepcopy(model.get("relation_contracts", [])),
        "actors": copy.deepcopy(model.get("actors", [])),
        "commands": copy.deepcopy(model.get("commands", [])),
        "events": copy.deepcopy(model.get("events", [])),
        "operations": copy.deepcopy(model.get("operations", [])),
        "milestones": copy.deepcopy(model.get("milestones", [])),
        "checkpoints": copy.deepcopy(model.get("checkpoints", [])),
        "flows": copy.deepcopy(model.get("flows", [])),
        "gate_placement": gate_placement(model),
    }
    return {key: values[key] for key in PAYLOAD_KEYS}


def build_payload(grammar: Mapping[str, Any]) -> dict:
    return payload(load_model(MODEL_PATH, grammar), grammar)


def _node_map(graph: Mapping[str, Any]) -> dict[str, MutableMapping[str, Any]]:
    nodes = graph.get("nodes", {})
    if isinstance(nodes, list):
        return {str(node["uid"]): node for node in nodes}
    return nodes


def _edges(graph: Mapping[str, Any]) -> list[MutableMapping[str, Any]]:
    return graph.get("edges", [])


def _related(
    graph: Mapping[str, Any], node: Mapping[str, Any], predicate: Mapping[str, Any]
) -> list[MutableMapping[str, Any]]:
    uid = str(node["uid"])
    direction = predicate.get("direction", "out")
    role = predicate.get("role")
    targets: list[str] = []
    for edge in _edges(graph):
        if edge.get("role") != role:
            continue
        if direction in ("out", "either") and str(edge.get("source")) == uid:
            targets.append(str(edge.get("target")))
        if direction in ("in", "either") and str(edge.get("target")) == uid:
            targets.append(str(edge.get("source")))
    nodes = _node_map(graph)
    return [nodes[target] for target in targets if target in nodes]


def _field_value(node: Mapping[str, Any], field: str) -> Any:
    return node.get("fields", {}).get(field)


def _field_lifecycle(
    model: Mapping[str, Any], field: str, node: Mapping[str, Any]
) -> Mapping[str, Any] | None:
    candidates = [
        lifecycle
        for lifecycle in model.get("lifecycles", [])
        if lifecycle.get("subject", {}).get("field") == field
        and _matches_subject(node, lifecycle["subject"])
    ]
    return candidates[0] if candidates else None


def _op_field_is(predicate, node, graph, actor, model) -> bool:
    del graph, actor, model
    return _field_value(node, predicate["field"]) == predicate.get("value")


def _op_field_at_least(predicate, node, graph, actor, model) -> bool:
    del graph, actor
    field = predicate["field"]
    lifecycle = _field_lifecycle(model, field, node)
    if lifecycle is None:
        return False
    order = _names(lifecycle.get("states", []))
    current = _field_value(node, field)
    wanted = predicate.get("value")
    return (
        current in order
        and wanted in order
        and order.index(current) >= order.index(wanted)
    )


def _op_has_relation(predicate, node, graph, actor, model) -> bool:
    del actor, model
    related = _related(graph, node, predicate)
    target_type = predicate.get("target_type")
    return any(
        target_type is None or item.get("type") == target_type for item in related
    )


def _op_all_related(predicate, node, graph, actor, model) -> bool:
    related = _related(graph, node, predicate)
    if not related:
        return predicate["empty"] == "pass"
    return all(
        evaluate(predicate["predicate"], item, graph, actor, model)
        for item in related
    )


def _op_any_related(predicate, node, graph, actor, model) -> bool:
    related = _related(graph, node, predicate)
    if not related:
        return predicate["empty"] == "pass"
    return any(
        evaluate(predicate["predicate"], item, graph, actor, model)
        for item in related
    )


def _op_actor_in(predicate, node, graph, actor, model) -> bool:
    del node, graph, model
    return actor in predicate.get("actors", predicate.get("values", []))


def _op_and(predicate, node, graph, actor, model) -> bool:
    return all(
        evaluate(item, node, graph, actor, model)
        for item in predicate.get("predicates", [])
    )


def _op_or(predicate, node, graph, actor, model) -> bool:
    return any(
        evaluate(item, node, graph, actor, model)
        for item in predicate.get("predicates", [])
    )


def _op_not(predicate, node, graph, actor, model) -> bool:
    return not evaluate(predicate["predicate"], node, graph, actor, model)


_OPERATIONS: dict[str, Callable[..., bool]] = {
    "actor_in": _op_actor_in,
    "all_related": _op_all_related,
    "and": _op_and,
    "any_related": _op_any_related,
    "field_at_least": _op_field_at_least,
    "field_is": _op_field_is,
    "has_relation": _op_has_relation,
    "not": _op_not,
    "or": _op_or,
}


def evaluate(
    predicate: Mapping[str, Any],
    node: Mapping[str, Any],
    graph: Mapping[str, Any],
    actor: str,
    model: Mapping[str, Any],
) -> bool:
    """Evaluate one predicate tree using the closed operation table."""
    operation = predicate.get("op")
    try:
        implementation = _OPERATIONS[operation]
    except KeyError as error:
        raise ModelError(
            f"unknown predicate operation {operation!r}; "
            f"{_known('operations', PREDICATE_OPERATIONS)}"
        ) from error
    return bool(implementation(predicate, node, graph, actor, model))


def _matches_subject(node: Mapping[str, Any], subject: Mapping[str, Any]) -> bool:
    if subject["kind"] == "role":
        return node.get("role") == subject["role"] and subject["field"] in node.get(
            "fields", {}
        )
    if subject["kind"] == "element" and node.get("type") != subject["tag"]:
        return False
    return subject["field"] in node.get("fields", {})


def _matching_subjects(
    graph: Mapping[str, Any], subject: Mapping[str, Any]
) -> list[MutableMapping[str, Any]]:
    if subject["kind"] == "role":
        rows = [
            edge for edge in _edges(graph) if edge.get("role") == subject["role"]
        ]
        for index, edge in enumerate(rows):
            edge.setdefault(
                "uid",
                f"{edge.get('source')}:{subject['role']}:{edge.get('target')}:{index}",
            )
            edge.setdefault("fields", {})
        return sorted(rows, key=lambda row: str(row["uid"]))
    return sorted(
        (
            node
            for node in _node_map(graph).values()
            if _matches_subject(node, subject)
        ),
        key=lambda row: str(row["uid"]),
    )


def _subjects(
    graph: Mapping[str, Any], lifecycle: Mapping[str, Any]
) -> list[MutableMapping[str, Any]]:
    return _matching_subjects(graph, lifecycle["subject"])


def _subject_by_uid(
    graph: Mapping[str, Any], subject: Mapping[str, Any], uid: Any
) -> MutableMapping[str, Any] | None:
    return next(
        (row for row in _matching_subjects(graph, subject) if str(row["uid"]) == str(uid)),
        None,
    )


def _write(subject: MutableMapping[str, Any], write: Mapping[str, Any]) -> None:
    subject.setdefault("fields", {})[write["field"]] = write.get("value")


class Interpreter:
    """A validated model bound to an optional grammar and a termination bound."""

    def __init__(
        self,
        model: Mapping[str, Any],
        grammar: Mapping[str, Any] | None = None,
        *,
        step_bound: int = 1000,
    ) -> None:
        validate_model(model, grammar)
        self.model = copy.deepcopy(model)
        self.grammar = grammar
        self.step_bound = step_bound
        self._lifecycles = {
            row["name"]: row for row in self.model.get("lifecycles", [])
        }
        self._gates = {row["name"]: row for row in self.model.get("gates", [])}

    def _transition(
        self,
        lifecycle: Mapping[str, Any],
        trigger: str,
        subject: Mapping[str, Any],
    ) -> Mapping[str, Any] | None:
        current = _field_value(subject, lifecycle["subject"]["field"])
        return next(
            (
                row
                for row in lifecycle.get("transitions", [])
                if row["trigger"] == trigger and row["from"] == current
            ),
            None,
        )

    def _apply(
        self,
        staged: MutableMapping[str, Any],
        lifecycle: Mapping[str, Any],
        transition: Mapping[str, Any],
        subject: MutableMapping[str, Any],
        actor: str,
        *,
        event: str | None,
        emitter: str | None,
        log: list[dict[str, Any]],
    ) -> tuple[bool, str | None]:
        reference = transition_reference(lifecycle["name"], transition)
        for gate_name in transition.get("gates", []):
            gate = self._gates[gate_name]
            if not evaluate(gate["predicate"], subject, staged, actor, self.model):
                log.append(
                    {
                        "subject": subject["uid"],
                        "transition": reference,
                        "event": event,
                        "emitter": emitter,
                        "gate": gate_name,
                        "rule": transition.get("rule_text") or None,
                        "verdict": "refused",
                    }
                )
                return False, gate_name
        field = lifecycle["subject"]["field"]
        subject.setdefault("fields", {})[field] = transition["to"]
        for write in transition.get("writes", []):
            _write(subject, write)
        log.append(
            {
                "subject": subject["uid"],
                "transition": reference,
                "event": event,
                "emitter": emitter,
                "gate": list(transition.get("gates", [])) or None,
                "rule": transition.get("rule_text") or None,
                "verdict": "taken",
            }
        )
        return True, None

    def fire(
        self,
        graph: MutableMapping[str, Any],
        command: str | Mapping[str, Any],
        actor: str,
    ) -> FireResult:
        """Dispatch and ripple on a staged copy, then atomically replace graph."""
        request = {"name": command} if isinstance(command, str) else dict(command)
        command_name = request.get("name")
        subject_uid = request.get("subject")
        commands = {row["name"]: row for row in self.model.get("commands", [])}
        operations = {
            row["name"]: row for row in self.model.get("operations", [])
        }
        if command_name not in commands and command_name not in operations:
            known = [*commands, *operations]
            return FireResult(
                "refused",
                (),
                f"unknown command {command_name!r}; {_known('commands', known)}",
                "command",
            )

        declared_actors = _names(self.model.get("actors", []))
        if declared_actors and actor not in declared_actors:
            return FireResult(
                "refused",
                (),
                f"unknown actor {actor!r}; {_known('actors', declared_actors)}",
                "actor",
            )

        staged = copy.deepcopy(graph)

        log: list[dict[str, Any]] = []
        queued: deque[tuple[str, str]] = deque()
        if command_name in operations:
            operation = operations[command_name]
            subject = _subject_by_uid(staged, operation["subject"], subject_uid)
            if subject is None:
                return FireResult(
                    "refused", (), f"unknown or mismatched subject {subject_uid!r}", "subject"
                )
            for write in operation.get("writes", []):
                _write(subject, write)
            log.append(
                {
                    "subject": subject["uid"],
                    "transition": None,
                    "event": None,
                    "emitter": None,
                    "gate": None,
                    "rule": None,
                    "verdict": "taken",
                    "operation": command_name,
                }
            )
            queued.extend(
                (event, str(subject["uid"]))
                for event in operation.get("emits", [])
            )
        else:
            declaration = commands[command_name]
            required_actor = declaration.get("actor")
            if required_actor is not None and required_actor != actor:
                return FireResult(
                    "refused",
                    (),
                    f"command {command_name!r} requires actor {required_actor!r}",
                    "actor",
                )
            lifecycle = self._lifecycles[declaration["lifecycle"]]
            subject = _subject_by_uid(staged, lifecycle["subject"], subject_uid)
            if subject is None:
                return FireResult(
                    "refused",
                    (),
                    f"unknown or mismatched subject {subject_uid!r}",
                    "subject",
                )
            transition = self._transition(
                lifecycle, declaration["trigger"], subject
            )
            if transition is None:
                return FireResult(
                    "refused", (), "no transition from current state", "transition"
                )
            taken, gate = self._apply(
                staged,
                lifecycle,
                transition,
                subject,
                actor,
                event=None,
                emitter=None,
                log=log,
            )
            if not taken:
                return FireResult(
                    "refused", tuple(log), f"gate {gate!r} refused", gate
                )
            queued.extend(
                (event, str(subject["uid"]))
                for event in transition.get("emits", [])
            )

        visited: set[tuple[str, str, str, str]] = set()
        steps = len(log)
        while queued:
            event, emitter = queued.popleft()
            for lifecycle in self.model.get("lifecycles", []):
                for ripple_subject in _subjects(staged, lifecycle):
                    transition = self._transition(lifecycle, event, ripple_subject)
                    if transition is None:
                        continue
                    key = (
                        lifecycle["name"],
                        str(ripple_subject["uid"]),
                        transition_reference(lifecycle["name"], transition),
                        event,
                    )
                    steps += 1
                    if key in visited or steps > self.step_bound:
                        return FireResult(
                            "refused",
                            tuple(log),
                            f"ripple exceeded step bound {self.step_bound}",
                            "step-bound",
                        )
                    visited.add(key)
                    taken, gate = self._apply(
                        staged,
                        lifecycle,
                        transition,
                        ripple_subject,
                        actor,
                        event=event,
                        emitter=emitter,
                        log=log,
                    )
                    if not taken:
                        return FireResult(
                            "refused", tuple(log), f"gate {gate!r} refused", gate
                        )
                    queued.extend(
                        (emitted, str(ripple_subject["uid"]))
                        for emitted in transition.get("emits", [])
                    )

        graph.clear()
        graph.update(staged)
        return FireResult("taken", tuple(log))

    def check(self, graph: Mapping[str, Any]) -> list[str]:
        """Report contract violations and forbidden cycles without mutation."""
        contracts = {
            row["role"]: row for row in self.model.get("relation_contracts", [])
        }
        nodes = _node_map(graph)
        found: list[str] = []
        for index, edge in enumerate(_edges(graph)):
            role = edge.get("role")
            if role not in contracts:
                found.append(f"edge {index}: role {role!r} has no relation contract")
                continue
            contract = contracts[role]
            source = nodes.get(str(edge.get("source")))
            target = nodes.get(str(edge.get("target")))
            if source is None or target is None:
                found.append(f"edge {index}: source or target is absent")
                continue
            if source.get("type") not in contract.get("from_types", []):
                found.append(
                    f"edge {index}: source type {source.get('type')!r} breaks {role}"
                )
            if target.get("type") not in contract.get("to_types", []):
                found.append(
                    f"edge {index}: target type {target.get('type')!r} breaks {role}"
                )
        for role, contract in contracts.items():
            if contract.get("admits_cycles", False):
                continue
            adjacency: dict[str, list[str]] = {}
            for edge in _edges(graph):
                if edge.get("role") == role:
                    adjacency.setdefault(str(edge["source"]), []).append(
                        str(edge["target"])
                    )
            visiting: set[str] = set()
            visited: set[str] = set()

            def visit(uid: str) -> bool:
                if uid in visiting:
                    return True
                if uid in visited:
                    return False
                visiting.add(uid)
                cyclic = any(visit(target) for target in adjacency.get(uid, []))
                visiting.remove(uid)
                visited.add(uid)
                return cyclic

            if any(visit(uid) for uid in list(adjacency)):
                found.append(
                    f"role {role!r} admits no cycles, but the graph has one"
                )
        return found


def fire(
    graph: MutableMapping[str, Any],
    command: str | Mapping[str, Any],
    actor: str,
) -> FireResult:
    """Dispatch against the shipped model; not called by the daemon yet."""
    return Interpreter(load_model()).fire(graph, command, actor)


def check(graph: Mapping[str, Any]) -> list[str]:
    return Interpreter(load_model()).check(graph)


def mermaid(lifecycle: Mapping[str, Any]) -> str:
    """Emit Mermaid with generated identifiers safe for dashed state names."""
    identifiers = {
        state["name"]: f"state_{index}"
        for index, state in enumerate(lifecycle.get("states", []))
    }
    lines = ["stateDiagram-v2"]
    for state in lifecycle.get("states", []):
        label = str(state.get("label") or state["name"]).replace('"', "'")
        lines.append(f'  state "{label}" as {identifiers[state["name"]]}')
    initial = lifecycle.get("initial")
    if initial in identifiers:
        lines.append(f"  [*] --> {identifiers[initial]}")
    for transition in lifecycle.get("transitions", []):
        gates = ", ".join(transition.get("gates", []))
        label = transition["trigger"] + (f" [{gates}]" if gates else "")
        lines.append(
            f"  {identifiers[transition['from']]} --> "
            f"{identifiers[transition['to']]} : {label}"
        )
    for terminal in lifecycle.get("terminal", []):
        if terminal in identifiers:
            lines.append(f"  {identifiers[terminal]} --> [*]")
    return "\n".join(lines) + "\n"
