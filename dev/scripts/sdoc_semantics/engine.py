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
MODEL_KEYS = (
    "schema",
    "model_version",
    "lifecycles",
    "actors",
    "commands",
    "events",
    "operations",
    "gates",
    "relation_contracts",
    "checkpoints",
    "milestones",
    "flows",
    "rules",
)
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
RULE_KINDS = ("transcription", "policy", "derived", "open")
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


def _require_shape(
    value: Any,
    required: Iterable[str],
    location: str,
    optional: Iterable[str] = (),
) -> None:
    if not isinstance(value, dict):
        raise ModelError(f"{location} must be an object")
    required_keys = tuple(required)
    allowed = set(required_keys) | set(optional)
    missing = [key for key in required_keys if key not in value]
    unexpected = [key for key in value if key not in allowed]
    if missing or unexpected:
        details = []
        if missing:
            details.append(f"missing {', '.join(missing)}")
        if unexpected:
            details.append(f"unexpected {', '.join(unexpected)}")
        raise ModelError(
            f"{location} has the wrong shape ({'; '.join(details)}); "
            f"known fields: {', '.join(required_keys)}"
        )


def _require_list(value: Any, location: str) -> None:
    if not isinstance(value, list):
        raise ModelError(f"{location} must be a list in presentation order")


def _validate_predicate(predicate: Any, location: str) -> None:
    if not isinstance(predicate, dict):
        raise ModelError(f"{location} predicate must be an object")
    operation = predicate.get("op")
    if operation not in PREDICATE_OPERATIONS:
        raise ModelError(
            f"{location} names unknown predicate operation {operation!r}; "
            f"{_known('operations', PREDICATE_OPERATIONS)}"
        )
    shapes = {
        "actor_in": (("op", "actors"), ()),
        "all_related": (
            ("op", "role", "predicate", "empty"),
            ("direction",),
        ),
        "and": (("op", "predicates"), ()),
        "any_related": (
            ("op", "role", "predicate", "empty"),
            ("direction",),
        ),
        "field_at_least": (("op", "field", "value"), ()),
        "field_is": (("op", "field", "value"), ()),
        "has_relation": (("op", "role"), ("direction", "target_type")),
        "not": (("op", "predicate"), ()),
        "or": (("op", "predicates"), ()),
    }
    required, optional = shapes[operation]
    _require_shape(predicate, required, f"{location} predicate", optional)
    if operation in ("and", "or"):
        _require_list(predicate["predicates"], f"{location}.{operation}.predicates")
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
        direction = predicate.get("direction", "out")
        if direction not in ("in", "out", "either"):
            raise ModelError(
                f"{location}.{operation} has unknown direction {direction!r}; "
                "known directions: in, out, either"
            )
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
        direction = predicate.get("direction", "out")
        if direction not in ("in", "out", "either"):
            raise ModelError(
                f"{location}.has_relation has unknown direction {direction!r}; "
                "known directions: in, out, either"
            )
        _require_reference(
            predicate.get("role"),
            _grammar_roles(grammar),
            "role",
            f"{location}.has_relation",
        )
        if predicate.get("target_type") is not None:
            _require_reference(
                predicate["target_type"],
                grammar.keys(),
                "element",
                f"{location}.has_relation",
            )
    elif operation == "has_relation":
        direction = predicate.get("direction", "out")
        if direction not in ("in", "out", "either"):
            raise ModelError(
                f"{location}.has_relation has unknown direction {direction!r}; "
                "known directions: in, out, either"
            )
    elif operation == "actor_in":
        declared = _names(model.get("actors", []))
        for actor in predicate["actors"]:
            _require_reference(actor, declared, "actor", f"{location}.actor_in")
    elif operation == "field_is" and grammar is not None:
        _require_reference(
            predicate.get("field"),
            _grammar_fields(grammar),
            "field",
            f"{location}.field_is",
        )
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
        states = [
            state
            for lifecycle in lifecycles
            for state in _names(lifecycle.get("states", []))
        ]
        _require_reference(
            predicate.get("value"), states, "state", f"{location}.field_at_least"
        )


def _validate_subject(
    subject: Mapping[str, Any],
    grammar: Mapping[str, Any] | None,
    location: str,
) -> None:
    if not isinstance(subject, dict):
        raise ModelError(f"{location} subject must be an object")
    kind = subject.get("kind")
    if kind not in ("element", "field", "role"):
        raise ModelError(
            f"{location} has unknown subject kind {kind!r}; "
            "known subject kinds: element, field, role"
        )
    required = {
        "element": ("kind", "tag", "field"),
        "field": ("kind", "field"),
        "role": ("kind", "role", "field"),
    }[kind]
    _require_shape(subject, required, f"{location} subject")
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
    if not isinstance(model, dict):
        raise ModelError("model document must be an object")
    if model.get("schema") != MODEL_SCHEMA:
        raise ModelError(
            f"unknown model schema {model.get('schema')!r}; known schemas: {MODEL_SCHEMA}"
        )
    _require_shape(model, MODEL_KEYS, "model document")
    if not isinstance(model["model_version"], str):
        raise ModelError("model_version must be a string")
    collection_names = MODEL_KEYS[2:]
    for collection in collection_names:
        _require_list(model[collection], f"model document {collection}")
        if not all(isinstance(row, dict) for row in model[collection]):
            raise ModelError(f"model document {collection} entries must be objects")

    lifecycles = model["lifecycles"]
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
        ("flow", _names(model.get("flows", []))),
        ("milestone", _names(model.get("milestones", []))),
        ("operation", _names(model.get("operations", []))),
    )
    for label, values in named_collections:
        if len(values) != len(set(values)):
            raise ModelError(f"duplicate {label} name; {_known(label + 's', values)}")
    rule_ids = [str(rule.get("id")) for rule in model["rules"]]
    if len(rule_ids) != len(set(rule_ids)):
        raise ModelError(f"duplicate rule id; {_known('rules', rule_ids)}")

    grammar_roles = _grammar_roles(grammar or {})
    grammar_types = list((grammar or {}).keys())
    for lifecycle in lifecycles:
        _require_shape(
            lifecycle,
            ("name", "subject", "states", "initial", "terminal", "transitions"),
            f"lifecycle {lifecycle.get('name')!r}",
        )
        name = lifecycle["name"]
        _require_list(lifecycle["states"], f"lifecycle {name!r} states")
        _require_list(lifecycle["terminal"], f"lifecycle {name!r} terminal")
        _require_list(lifecycle["transitions"], f"lifecycle {name!r} transitions")
        for state in lifecycle["states"]:
            _require_shape(
                state,
                ("name", "label", "note"),
                f"lifecycle {name!r} state {state.get('name')!r}",
            )
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
            _require_shape(
                transition,
                (
                    "trigger",
                    "from",
                    "to",
                    "gates",
                    "writes",
                    "emits",
                    "rule_text",
                    "settled",
                ),
                location,
            )
            for key in ("gates", "writes", "emits"):
                _require_list(transition[key], f"{location} {key}")
            for write in transition["writes"]:
                _require_shape(write, ("field", "value"), f"{location} write")
                if grammar is not None:
                    _require_reference(
                        write["field"], _grammar_fields(grammar), "field", location
                    )
            _require_reference(transition.get("from"), states, "state", location)
            _require_reference(transition.get("to"), states, "state", location)
            for gate in transition.get("gates", []):
                _require_reference(gate, gate_names, "gate", location)
            for event in transition.get("emits", []):
                _require_reference(event, event_names, "event", location)

        _validate_subject(lifecycle.get("subject", {}), grammar, f"lifecycle {name!r}")

    for gate in model.get("gates", []):
        _require_shape(
            gate, ("name", "sees", "predicate"), f"gate {gate.get('name')!r}"
        )
        _require_list(gate["sees"], f"gate {gate['name']!r} sees")
        _validate_predicate(gate.get("predicate"), f"gate {gate['name']!r}")
        _validate_predicate_references(
            gate["predicate"], model, grammar, f"gate {gate['name']!r}"
        )

    for command in model.get("commands", []):
        _require_shape(
            command,
            ("name", "lifecycle", "trigger"),
            f"command {command.get('name')!r}",
            ("actor",),
        )
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
        _require_shape(
            operation,
            ("name", "subject", "writes", "emits"),
            f"operation {operation.get('name')!r}",
        )
        _require_list(operation["writes"], f"operation {operation['name']!r} writes")
        _require_list(operation["emits"], f"operation {operation['name']!r} emits")
        _validate_subject(
            operation.get("subject", {}), grammar, f"operation {operation['name']!r}"
        )
        lifecycle_fields = {
            row["subject"]["field"] for row in model.get("lifecycles", [])
        }
        for write in operation["writes"]:
            _require_shape(
                write, ("field", "value"), f"operation {operation['name']!r} write"
            )
            if write["field"] in lifecycle_fields:
                raise ModelError(
                    f"operation {operation['name']!r} writes lifecycle field "
                    f"{write['field']!r}; operations mutate without moving state"
                )
            if grammar is not None:
                _require_reference(
                    write["field"],
                    _grammar_fields(grammar),
                    "field",
                    f"operation {operation['name']!r}",
                )
        for event in operation.get("emits", []):
            _require_reference(
                event, event_names, "event", f"operation {operation['name']!r}"
            )
    for contract in model.get("relation_contracts", []):
        _require_shape(
            contract,
            ("role", "from_types", "to_types", "admits_cycles", "propagates"),
            f"relation contract {contract.get('role')!r}",
        )
        _require_list(
            contract["from_types"],
            f"relation contract {contract['role']!r} from_types",
        )
        _require_list(
            contract["to_types"],
            f"relation contract {contract['role']!r} to_types",
        )
        if grammar is not None:
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
        _require_shape(
            milestone,
            ("name", "subject", "achieved_when", "stale_when"),
            f"milestone {milestone.get('name')!r}",
        )
        _validate_subject(
            milestone["subject"], grammar, f"milestone {milestone['name']!r}"
        )
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
        _require_shape(flow, ("name", "steps"), f"flow {flow.get('name')!r}")
        _require_list(flow["steps"], f"flow {flow['name']!r} steps")
        for index, step in enumerate(flow.get("steps", [])):
            _require_shape(
                step,
                ("transition", "expected"),
                f"flow {flow['name']!r} step {index}",
                ("refused_by",),
            )
            if step["expected"] not in ("taken", "refused"):
                raise ModelError(
                    f"flow {flow['name']!r} step {index} has unknown outcome "
                    f"{step['expected']!r}; known outcomes: taken, refused"
                )
            if step["expected"] == "refused" and "refused_by" not in step:
                raise ModelError(
                    f"flow {flow['name']!r} step {index} refuses without naming a gate"
                )
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
    for actor in model.get("actors", []):
        _require_shape(actor, ("name",), f"actor {actor.get('name')!r}")
    for event in model.get("events", []):
        _require_shape(
            event, ("name", "external"), f"event {event.get('name')!r}"
        )
        if not isinstance(event["external"], bool):
            raise ModelError(f"event {event['name']!r} external must be a bool")
    for checkpoint in model.get("checkpoints", []):
        _require_shape(
            checkpoint,
            ("name", "sees"),
            f"checkpoint {checkpoint.get('name')!r}",
        )
        _require_list(checkpoint["sees"], f"checkpoint {checkpoint['name']!r} sees")
    for rule in model.get("rules", []):
        _require_shape(
            rule,
            ("id", "text", "kind", "settled", "cites"),
            f"rule {rule.get('id')!r}",
        )
        if rule["kind"] not in RULE_KINDS:
            raise ModelError(
                f"rule {rule['id']!r} has unknown kind {rule['kind']!r}; "
                f"{_known('rule kinds', RULE_KINDS)}"
            )
        _require_list(rule["cites"], f"rule {rule['id']!r} cites")


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
        options_by_tag = grammar_options(field, grammar)
        for tag in applies_to(lifecycle["subject"], grammar):
            options = options_by_tag.get(tag, [])
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


def _rules_for(
    lifecycle: Mapping[str, Any], rules: Iterable[Mapping[str, Any]]
) -> list[dict[str, Any]]:
    prefix = str(lifecycle["name"]).replace("_", "-") + "-"
    return [dict(rule) for rule in rules if str(rule["id"]).startswith(prefix)]


def machine_payload(
    lifecycle: Mapping[str, Any],
    grammar: Mapping[str, Any],
    rules: Iterable[Mapping[str, Any]] = (),
) -> dict:
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
        "rules": _rules_for(lifecycle, rules),
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
        machines[lifecycle["name"]] = machine_payload(
            lifecycle, grammar, model.get("rules", [])
        )
    by_type: dict[str, list[str]] = {tag: [] for tag in grammar}
    for name, machine in machines.items():
        for tag in machine["applies_to"]:
            by_type[tag].append(name)
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


def adapt_graph(loaded_graph: Any) -> dict[str, Any]:
    """Project an ``sdoc_model.Graph`` into the interpreter's tiny graph shape.

    This is deliberately duck typed: importing the StrictDoc-backed model here
    would put that implementation and its dependencies in the interpreter's
    closure. Callers that already hold a loaded graph cross the seam explicitly.
    """
    nodes: dict[str, dict[str, Any]] = {}
    edges: list[dict[str, str]] = []
    for source in loaded_graph.iter_nodes():
        uid = str(source.reserved_uid)
        fields = {
            str(name): entries[0].get_text_value()
            for name, entries in source.ordered_fields_lookup.items()
            if entries
        }
        nodes[uid] = {
            "uid": uid,
            "type": str(source.node_type),
            "fields": fields,
        }
        for relation in source.relations:
            target = getattr(relation, "ref_uid", None)
            role = getattr(relation, "role", None)
            if target is not None and role:
                edges.append(
                    {
                        "role": str(role),
                        "source": uid,
                        "target": str(target),
                    }
                )
    return {"nodes": nodes, "edges": edges}


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

    def _transitions(
        self,
        lifecycle: Mapping[str, Any],
        trigger: str,
        subject: Mapping[str, Any],
    ) -> list[Mapping[str, Any]]:
        current = _field_value(subject, lifecycle["subject"]["field"])
        return [
            row
            for row in lifecycle.get("transitions", [])
            if row["trigger"] == trigger and row["from"] == current
        ]

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
            transitions = self._transitions(
                lifecycle, declaration["trigger"], subject
            )
            if not transitions:
                return FireResult(
                    "refused", (), "no transition from current state", "transition"
                )
            if len(transitions) > 1:
                return FireResult(
                    "refused",
                    (),
                    "ambiguous transition from current state",
                    "ambiguous-dispatch",
                )
            transition = transitions[0]
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
                    transitions = self._transitions(lifecycle, event, ripple_subject)
                    if not transitions:
                        continue
                    if len(transitions) > 1:
                        return FireResult(
                            "refused",
                            tuple(log),
                            "ambiguous ripple transition from current state",
                            "ambiguous-dispatch",
                        )
                    transition = transitions[0]
                    key = (
                        lifecycle["name"],
                        str(ripple_subject["uid"]),
                        transition_reference(lifecycle["name"], transition),
                        event,
                    )
                    repeated = key in visited
                    visited.add(key)
                    steps += 1
                    if steps > self.step_bound:
                        kind = "cyclic ripple" if repeated else "ripple"
                        return FireResult(
                            "refused",
                            tuple(log),
                            f"{kind} exceeded step bound {self.step_bound}",
                            "step-bound",
                        )
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
            for cycle in _simple_cycles(adjacency):
                found.append(
                    f"role {role!r} admits no cycles: {' -> '.join(cycle)}"
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


def _simple_cycles(adjacency: Mapping[str, Iterable[str]]) -> list[tuple[str, ...]]:
    """Enumerate each directed simple cycle once, with its least UID first."""
    cycles: list[tuple[str, ...]] = []
    nodes = sorted(
        set(adjacency) | {target for targets in adjacency.values() for target in targets}
    )
    for start in nodes:

        def walk(current: str, path: tuple[str, ...], seen: set[str]) -> None:
            for target in sorted(set(adjacency.get(current, ()))):
                if target == start:
                    cycles.append((*path, start))
                elif target >= start and target not in seen:
                    walk(target, (*path, target), seen | {target})

        walk(start, (start,), {start})
    return cycles


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
