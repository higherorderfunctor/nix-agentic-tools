"""Version-one handwritten ABI reference; validates an unordered fact collection."""

from collections import defaultdict
import json
import math
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


def path_scalar(absolute_text):
    require(text(absolute_text).startswith("/"), "expected evaluated absolute path")
    return "evaluated-path-json-v1", text(canonical(absolute_text))


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
            elif kind in ("bool", "int"):
                require(type(value) is int and 0 <= value <= (1 if kind == "bool" else 2147483647), "invalid native integer")
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
        owner = "nx_value_members" if first == "member" else f"nx_{first}s"
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
    values = owners["value"]
    result = one("request_results")
    scalar = one("scalar_values")
    links = one("observation_values")
    member_links = one("member_values")
    origin_files = one("origin_files")
    origin_targets = defaultdict(set)
    value_contexts = defaultdict(set)
    for file, root, relative, digest, _ in tables["nx_files"]:
        require(len(key_parts(root, "root")) == 2, "invalid root identity")
        require(relative and not relative.startswith("/") and ".." not in relative.split("/"), "root-escaping source path")
        require(file == key("file", [root, relative, digest]), "source identity mismatch")
    for anchor, file, start, end, kind, child in tables["nx_anchors"]:
        require(end >= start, "reversed anchor span")
        child_indices = json_path(child, True)
        require(all(type(i) is int for i in child_indices), "invalid structural child path")
        require(anchor == key("anchor", [file, str(start), str(end), kind, child]), "anchor identity mismatch")
    for _, _, _, instance in tables["nx_contexts"]:
        json_path(instance, True)
    for child, parent, parent_option, kind, member in tables["nx_context_parents"]:
        require(context[child][1] == context[parent][1] and option[parent_option][1] == parent, "cross-context parent")
        if kind == "list":
            require(re.fullmatch(r"0|[1-9][0-9]*", member), "invalid list index")
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
    for obs, req, kind, subject, stage, state in tables["nx_observations"]:
        target, ctx = request[req][1:3]
        if kind == "config-path":
            json_path(subject)
        else:
            require(subject in owners[kind], "invalid observation subject")
            if kind in ("option", "definition"):
                opt = subject if kind == "option" else owners["definition"][subject][1]
                require(option[opt][1] == ctx, "observation subject context mismatch")
            else:
                value_contexts[owners["member"][subject][1]].add((target, ctx))
        require(obs not in links or state == "observed", "unsuccessful observation has a value")
        require(state != "observed" or result.get(req, [None])[0] in ("complete", "partial"), "observation from unsuccessful projection")
        if obs in links:
            value_contexts[links[obs][0]].add((target, ctx))
        if (kind == "option" and state == "observed" and stage == priority_witness["stage"]
                and request[req][3] == priority_witness["domain"]
                and request[req][4] == option[subject][2] and request[req][5] == priority_witness["facet"]):
            observed_priorities.add(subject)
    for opt, _ in tables["nx_option_priority"]:
        require(opt in defined_options and opt in observed_priorities, "option priority lacks defined observation")
    # Scope flows through known membership, independent of input row ordering.
    changed = True
    while changed:
        changed = False
        for member, parent, *_ in tables["nx_value_members"]:
            if member in member_links:
                child = member_links[member][0]
                before = len(value_contexts[child])
                value_contexts[child].update(value_contexts[parent])
                changed |= len(value_contexts[child]) != before
    require(all(len(scopes) <= 1 for scopes in value_contexts.values()), "cross-context value observation")
    for member, child in tables["nx_member_values"]:
        observations = [o for o in tables["nx_observations"] if o[2:4] == ["member", member]]
        require(any(o[5] == "observed" and links.get(o[0]) == [child] for o in observations), "member value lacks successful observation")
    for req, state, reason, _ in tables["nx_request_results"]:
        require(state != "complete" or reason not in ("timeout", "text-field-too-large"), "refusal cannot be complete")
    diagnostic_requests = one("diagnostic_requests")
    diagnostic_targets = one("diagnostic_targets")
    diagnostic_origins = one("diagnostic_origins")
    for diag, run, code, _ in tables["nx_diagnostics"]:
        target = diagnostic_targets.get(diag, [None])[0]
        req = diagnostic_requests.get(diag, [None])[0]
        if req is not None:
            require(target is None or request[req][1] == target, "diagnostic target mismatch")
            target = request[req][1]
            require(code not in ("timeout", "text-field-too-large") or result.get(req, [None])[0] != "complete", "refused request marked complete")
        if target is not None:
            require(owners["target"][target][1] == run, "diagnostic run mismatch")
        if diag in diagnostic_origins:
            origin_targets[diagnostic_origins[diag][0]].add(run)
    for opt, _, origin in [row[1:] for row in tables["nx_definitions"]] + tables["nx_option_declarations"]:
        origin_targets[origin].add(owners["target"][context[option[opt][1]][1]][1])
    for _, ctx, _, origin, _ in tables["nx_modules"]:
        origin_targets[origin].add(owners["target"][context[ctx][1]][1])
    admitted = defaultdict(set)
    for target, file, _ in tables["nx_target_inputs"]:
        admitted[file].add(owners["run"][owners["target"][target][1]][5])
    for origin, runs in origin_targets.items():
        if origin in origin_files:
            require(all(owners["run"][run][5] in admitted[origin_files[origin][0]] for run in runs), "cross-snapshot origin")
    for parent, members in _groups(tables["nx_value_members"], 1).items():
        kind, completeness = values[parent][1:]
        require(kind in ("attrset", "list"), "value with members is not a container")
        require(len({m[3] for m in members}) == len(members) and len({m[4] for m in members}) == len(members), "duplicate membership")
        for _, _, member_kind, member_key, ordinal in members:
            require(member_kind == ("list" if kind == "list" else "attribute"), "member kind mismatch")
            if kind == "list":
                require(member_key == str(ordinal), "list key/ordinal mismatch")
        if kind == "list" and completeness == "complete":
            require(sorted(m[4] for m in members) == list(range(len(members))), "incomplete list ordinals")
    for opt, definitions in _groups(tables["nx_definitions"], 1).items():
        require(len({d[2] for d in definitions}) == len(definitions), "duplicate definition ordinal")
        complete = any(r[2] == option[opt][1] and r[3] == "definition-value" and r[4] == option[opt][2]
                       and result.get(r[0], [None])[0] == "complete" for r in tables["nx_requests"])
        if complete:
            require(sorted(d[2] for d in definitions) == list(range(len(definitions))), "incomplete definition ordinals")
    for value, kind, _ in tables["nx_values"]:
        if kind not in CONTRACT["scalarEncodings"]:
            require(value not in scalar, "opaque/container scalar payload")
            continue
        require(value in scalar and scalar[value][0] == CONTRACT["scalarEncodings"][kind], "scalar encoding mismatch")
        payload = scalar[value][1]
        if kind in ("path", "string"):
            require(isinstance(decoded(payload), str), "invalid string scalar")
            if kind == "path":
                require(path_scalar(decoded(payload))[1] == payload, "invalid path scalar")
        elif kind == "integer":
            require(DECIMAL.fullmatch(payload), "invalid integer scalar")
        elif kind == "boolean":
            require(payload in ("false", "true"), "invalid boolean scalar")
        elif kind == "null":
            require(payload == "null", "invalid null scalar")
        else:
            try:
                number = float.fromhex(payload)
                require(math.isfinite(number) and number.hex() == payload, "invalid float scalar")
            except (ValueError, OverflowError) as error:
                raise ValueError("invalid float scalar") from error
    for value, _, kind, output in tables["nx_string_context"]:
        require(values[value][1] == "string" and (bool(output) == (kind == "output")), "invalid string context")
    for parent, _, child in tables["nx_module_imports"]:
        require(owners["module"][parent][1] == owners["module"][child][1], "cross-context module import")
    for ctx, _, module in tables["nx_module_roots"]:
        require(owners["module"][module][1] == ctx, "cross-context module root")


def _groups(rows, column):
    grouped = defaultdict(list)
    for row in rows:
        grouped[row[column]].append(row)
    return grouped


def dbscheme():
    """Render the typed inventory to verify the committed schema projection."""
    declarations = []
    for table, columns in COLUMNS.items():
        fields = []
        for name, kind in columns:
            owner = "nx_value_members" if kind == "member" else f"nx_{kind}s"
            if kind in CONTRACT["entities"] and table == owner and name == kind:
                fields.append(f"unique int {name}: @nx_{kind}")
            else:
                native = "string" if kind == "text" else "int"
                target = native if kind in ("bool", "int", "text") else f"@nx_{kind}"
                fields.append(f"{native} {name}: {target} ref")
        declarations.append(f"{table}({', '.join(fields)});")
    return "\n".join(declarations) + "\n"
