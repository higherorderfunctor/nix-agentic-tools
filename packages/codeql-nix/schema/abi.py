"""Version-one handwritten ABI reference; validates an unordered fact collection."""

from collections import defaultdict
import json
from pathlib import Path
import re

CONTRACT = json.loads(Path(__file__).with_name("contract.json").read_text())
COLUMNS = {table: [part.split(":") for part in rule["columns"].split()]
           for table, rule in CONTRACT["relations"].items()}
DECIMAL = re.compile(r"(?:0|-?[1-9][0-9]*)\Z")


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def text(value, bounded=True):
    require(isinstance(value, str), "expected text")
    try:
        size = len(value.encode("utf-8"))
    except UnicodeError as error:
        raise ValueError("invalid UTF-8 text") from error
    require(not bounded or size <= CONTRACT["maxExactTextBytes"], "text-field-too-large")
    return value


def canonical(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def key(namespace, parts):
    require(isinstance(namespace, str) and re.fullmatch(r"[a-z][a-z0-9-]*", namespace), "invalid namespace")
    require(isinstance(parts, list), "expected key components")
    return f"nixql:v1:{namespace}:" + "".join(
        f"{len(text(part, False).encode('utf-8'))}:{part}" for part in parts)


def key_parts(value, namespace):
    raw = text(value, False).encode("utf-8")
    prefix = f"nixql:v1:{namespace}:".encode()
    require(raw.startswith(prefix), "incorrect key namespace")
    raw = raw[len(prefix):]
    parts = []
    while raw:
        size, delimiter, raw = raw.partition(b":")
        require(delimiter and re.fullmatch(rb"0|[1-9][0-9]*", size), "invalid key framing")
        # Comparing digit lengths avoids Python's decimal conversion ceiling.
        require(len(size) <= len(str(len(raw))), "invalid key length")
        length = int(size)
        require(length <= len(raw), "truncated key")
        try:
            parts.append(raw[:length].decode("utf-8"))
        except UnicodeError as error:
            raise ValueError("split UTF-8 key component") from error
        raw = raw[length:]
    return parts


def path(segments):
    require(isinstance(segments, list) and all(isinstance(p, str) for p in segments), "expected string path segments")
    return text(canonical(segments))


def priority(value):
    require(isinstance(value, str) and DECIMAL.fullmatch(value), "invalid decimal priority")
    require(len(value.lstrip("-")) <= 19 and -(2**63) <= int(value) < 2**63, "priority-domain-unsupported")
    return value


def decoded(value):
    try:
        result = json.loads(value)
        require(canonical(result) == value, "JSON is not canonical")
        return result
    except (TypeError, json.JSONDecodeError, OverflowError) as error:
        raise ValueError("invalid JSON") from error


def json_path(value, indices=False):
    result = decoded(value)
    require(isinstance(result, list) and all(isinstance(p, str) or
            (indices and type(p) is int and p >= 0) for p in result), "invalid path segments")
    return result


def context_steps(value):
    """Concrete instance steps; key order and member key encodings are canonical."""
    steps = decoded(value)
    require(isinstance(steps, list) and all(isinstance(step, dict) and
            list(step) == ["option", "memberKind", "memberKey"] for step in steps), "invalid context instance path")
    for step in steps:
        path(step["option"])
        kind, member = step["memberKind"], text(step["memberKey"])
        require(kind in CONTRACT["enums"]["nx_context_parents.memberKind"], "invalid enum")
        require(kind == "attribute" or (kind == "submodule" and member == "") or
                (kind == "index" and re.fullmatch(r"0|[1-9][0-9]*", member)), "invalid member key")
    return steps


def library_formal(anchors, function, formal):
    """The bounded source shape accepted for an authenticated lib argument."""
    fn, argument = anchors[function], anchors[formal]
    fn_path, arg_path = json_path(fn[5], True), json_path(argument[5], True)
    if not (fn[1] == argument[1] and fn[4] == "function_expression" and
            argument[4] == "identifier" and len(fn_path) == 1 and
            len(arg_path) == len(fn_path) + 3 and arg_path[:len(fn_path)] == fn_path):
        return False
    paths = {(row[1], row[5]): row for row in anchors.values()}
    chain = [paths.get((fn[1], canonical(arg_path[:length])))
             for length in (len(arg_path) - 2, len(arg_path) - 1)]
    return all(chain) and [row[4] for row in chain] == ["formals", "formal"]


def validate(rows):
    require(isinstance(rows, list), "expected relation rows")
    tables = defaultdict(list)
    owners = {entity: {} for entity in CONTRACT["entities"]}
    keys = defaultdict(set)
    for item in rows:
        require(isinstance(item, (list, tuple)) and len(item) == 2, "invalid row")
        table, arguments = item
        require(isinstance(table, str) and table in COLUMNS, "unknown relation")
        require(isinstance(arguments, list) and len(arguments) == len(COLUMNS[table]), "incorrect arity")
        for (column, kind), value in zip(COLUMNS[table], arguments):
            if kind == "text":
                text(value)
            elif kind == "bool":
                require(type(value) is bool, "invalid Boolean")
            elif kind == "int":
                require(type(value) is int and 0 <= value <= 2147483647, "invalid native integer")
            else:
                key_parts(value, kind)
            enum = CONTRACT["enums"].get(f"{table}.{column}")
            require(enum is None or value in enum, "invalid enum")
            if column == "priorityDecimal":
                priority(value)
        identity = tuple(arguments[index] for index in CONTRACT["relations"][table]["key"])
        require(identity not in keys[table], "duplicate primary key")
        keys[table].add(identity)
        tables[table].append(arguments)
    for table, arguments in rows:
        first = COLUMNS[table][0][1]
        owner = f"nx_{first}s"
        if first in owners and table == owner:
            owners[first][arguments[0]] = arguments
    for table, arguments in rows:
        for (_, kind), value in zip(COLUMNS[table], arguments):
            require(kind not in owners or value in owners[kind], "missing foreign entity")

    def one(table):
        return {row[0]: row[1:] for row in tables["nx_" + table]}

    context = owners["context"]
    option = owners["option"]
    request = owners["request"]
    result = one("request_results")
    origin_files = one("origin_files")
    origin_targets = defaultdict(set)
    for file, root, relative, digest, _ in tables["nx_files"]:
        require(len(key_parts(root, "root")) == 2, "invalid root identity")
        require(relative and not relative.startswith("/") and ".." not in relative.split("/"), "root-escaping source path")
        require(file == key("file", [root, relative, digest]), "source identity mismatch")
    for anchor, file, start, end, kind, child in tables["nx_anchors"]:
        require(end >= start, "reversed anchor span")
        child_indices = json_path(child, True)
        require(all(type(i) is int for i in child_indices), "invalid structural child path")
        require(anchor == key("anchor", [file, str(start), str(end), kind, child]), "anchor identity mismatch")
    for req, function, formal, lib_hash, model_hash in tables["nx_module_lib_bindings"]:
        target = owners["target"][request[req][1]]
        require(result.get(req, [None])[0] == "complete" and request[req][5] in
                ("selection", "all-definitions"), "library binding lacks successful request")
        require(lib_hash == target[6] and model_hash == owners["run"][target[1]][4],
                "library binding fingerprint mismatch")
        require(library_formal(owners["anchor"], function, formal), "formal does not belong to function")
        fn = owners["anchor"][function]
        require(any(t == target[0] and f == fn[1] for t, f, _ in tables["nx_target_inputs"]),
                "library binding source not admitted")
    parents = one("context_parents")
    for ctx, _, kind, instance in tables["nx_contexts"]:
        # Each concrete path extends its parent's by one step, so chains end at a root.
        require((kind == "root") == (context_steps(instance) == []) and (kind == "root") != (ctx in parents),
                "context instance path or parent mismatch")
    for child, parent, opt, kind, member in tables["nx_context_parents"]:
        require(context[child][1] == context[parent][1], "context parent target mismatch")
        require(option[opt][1] == parent, "context parent option outside parent context")
        step = {"option": json_path(option[opt][2]), "memberKind": kind, "memberKey": member}
        require(context_steps(context[child][3]) == context_steps(context[parent][3]) + [step],
                "context step mismatch")
    for _, _, segments in tables["nx_options"]:
        json_path(segments)
    for _, line, column, _ in tables["nx_origin_positions"]:
        require(line > 0 and column > 0, "invalid origin position")
    defined_options = set()
    for opt, field, payload in tables["nx_option_metadata"]:
        require(not isinstance(decoded(payload), (dict, list)), "metadata is not scalar")
        if field == "isDefined" and payload == "true":
            defined_options.add(opt)
    for req, target, ctx, _, segments, *_ in tables["nx_requests"]:
        require(context[ctx][1] == target, "request target/context mismatch")
        json_path(segments)
    priority_witness = CONTRACT["priority"]["optionWitness"]
    observed_priorities = set()
    subjects = defaultdict(list)
    for kind in ("definition", "option"):
        for observation, subject in tables[f"nx_observation_{kind}s"]:
            subjects[observation].append((kind, subject))
    for observation, req, stage, state in tables["nx_observations"]:
        require(len(subjects[observation]) == 1, "observation requires exactly one typed subject")
        kind, subject = subjects[observation][0]
        ctx = request[req][2]
        opt = subject if kind == "option" else owners["definition"][subject][1]
        require(option[opt][1] == ctx, "observation subject context mismatch")
        require(state != "observed" or result.get(req, [None])[0] in ("complete", "partial"), "observation from unsuccessful projection")
        if (kind == "option" and state == "observed" and stage == priority_witness["stage"]
                and request[req][3] == priority_witness["domain"]
                and request[req][4] == option[subject][2] and request[req][5] in priority_witness["facets"]):
            observed_priorities.add(subject)
    witnessed = {(req, kind, subject) for observation, req, _, state in tables["nx_observations"]
                 if state == "observed" and result.get(req, [None])[0] in ("complete", "partial")
                 for kind, subject in subjects[observation]}
    for definition, _ in tables["nx_definition_order"]:
        parent = owners["definition"][definition][1]
        require(any(kind == "definition" and subject == definition and
                    (req, "option", parent) in witnessed and
                    request[req][5] in ("definitions", "selection")
                    for req, kind, subject in witnessed), "order lacks same-request retained observation")
    for opt, _ in tables["nx_option_priority"]:
        require(opt in defined_options and opt in observed_priorities, "option priority lacks defined observation")
    for req, state, reason, _ in tables["nx_request_results"]:
        require(state != "complete" or reason not in ("timeout", "text-field-too-large"), "refusal cannot be complete")
    diagnostic_requests = one("diagnostic_requests")
    diagnostic_targets = one("diagnostic_targets")
    for diag, run, code, _ in tables["nx_diagnostics"]:
        target = diagnostic_targets.get(diag, [None])[0]
        req = diagnostic_requests.get(diag, [None])[0]
        if req is not None:
            require(target is None or request[req][1] == target, "diagnostic target mismatch")
            target = request[req][1]
            require(code not in ("timeout", "text-field-too-large") or result.get(req, [None])[0] != "complete", "refused request marked complete")
        if target is not None:
            require(owners["target"][target][1] == run, "diagnostic run mismatch")
    definition_ordinals = defaultdict(set)
    for _, opt, ordinal, _ in tables["nx_definitions"]:
        require(ordinal not in definition_ordinals[opt], "duplicate definition ordinal")
        definition_ordinals[opt].add(ordinal)
    for req, _, ctx, _, segments, facet, *_ in tables["nx_requests"]:
        if facet in ("definitions", "selection") and result.get(req, [None])[0] == "complete":
            selected = {opt for opt, context_key, path_json in tables["nx_options"] if (context_key, path_json) == (ctx, segments)}
            witnessed = {subject for observation, request_key, _, state in tables["nx_observations"]
                         if request_key == req and state == "observed"
                         for kind, subject in subjects[observation] if kind == "option"}
            selected &= witnessed
            require(selected and result[req][2] > 0, "definitions lack observed completion")
            for opt in selected:
                ordinals = definition_ordinals[opt]
                require(ordinals == set(range(len(ordinals))), "noncontiguous definition ordinals")
    for opt, _, origin in [row[1:] for row in tables["nx_definitions"]] + tables["nx_option_declarations"]:
        origin_targets[origin].add(owners["target"][context[option[opt][1]][1]][1])
    admitted = defaultdict(set)
    for target, file, _ in tables["nx_target_inputs"]:
        admitted[file].add(owners["run"][owners["target"][target][1]][5])
    for origin, runs in origin_targets.items():
        if origin in origin_files:
            require(all(owners["run"][run][5] in admitted[origin_files[origin][0]] for run in runs), "cross-snapshot origin")


def dbscheme():
    """Render the typed inventory to verify the committed schema projection."""
    declarations = []
    for table, columns in COLUMNS.items():
        fields = []
        for name, kind in columns:
            owner = f"nx_{kind}s"
            if kind in CONTRACT["entities"] and table == owner and name == kind:
                fields.append(f"unique int {name}: @nx_{kind}")
            else:
                native = "string" if kind == "text" else "int"
                target = native if kind in ("bool", "int", "text") else f"@nx_{kind}"
                fields.append(f"{native} {name}: {target} ref")
        declarations.append(f"{table}({', '.join(fields)});")
    return "\n".join(declarations) + "\n"
