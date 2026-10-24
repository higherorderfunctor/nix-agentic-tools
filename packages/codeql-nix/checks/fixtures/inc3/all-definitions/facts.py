"""Contract-only M3d packets. No producer implementation is imported."""

import hashlib
import json
from pathlib import Path


def key(kind, parts):
    return "nixql:v1:" + kind + ":" + "".join(
        str(len(part.encode("utf-8"))) + ":" + part for part in parts
    )


def rows(packet, relation):
    return [arguments for table, arguments in packet["facts"] if table == relation]


def canonical(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def _anchor_id(file, start, end, kind, child):
    return key("anchor", [file, str(start), str(end), kind, canonical(child)])


def _anchor(root, relative, start, end, kind, child):
    file = key("file", [root, relative, "source-content"])
    return file, _anchor_id(file, start, end, kind, child)


def _byte_span(source, text):
    """Return an exact UTF-8 byte span for one literal source fragment."""
    prefix = source[:source.index(text)]
    start = len(prefix.encode("utf-8"))
    return start, start + len(text.encode("utf-8"))


def baseline_shapes():
    """Reviewed source spans, derived from fixture bytes rather than producer output."""
    directory = Path(__file__).parent
    ordinary = (directory / "ordinary.nix").read_text()
    fallback = (directory / "fallback.nix").read_text()
    inactive = (directory / "inactive.nix").read_text()
    return [
        {
            "binding": "ordinary.nix",
            "span": _byte_span(ordinary, "demo.answer"),
            "origin": "ordinary.nix",
            "module": "ordinary",
            "active": "true",
            "selected": "true",
            "priority": "100",
            "chain": [],
        },
        {
            "binding": "fallback.nix",
            "span": _byte_span(fallback, "demo.answer"),
            "wrapper_span": _byte_span(fallback, "lib.mkDefault 2"),
            "origin": "fallback.nix",
            "module": "fallback",
            "active": "true",
            "selected": "false",
            "priority": "1000",
            "chain": [{"kind": "override", "priority": "1000"}],
        },
        {
            "binding": "inactive.nix",
            "span": _byte_span(inactive, "demo.answer"),
            "wrapper_span": _byte_span(
              inactive,
              "lib.mkIf false (lib.mkOverride 10 (throw \"M3d inactive\"))",
            ),
            "override_span": _byte_span(
              inactive,
              "lib.mkOverride 10 (throw \"M3d inactive\")",
            ),
            "origin": "inactive.nix",
            "module": "inactive",
            "active": "false",
            "selected": "false",
            "priority": "10",
            "chain": [{"kind": "if", "truth": "false"}, {"kind": "override", "priority": "10"}],
        },
    ]


def _wrapper_span(shape, wrapper):
    span_key = wrapper["kind"] + "_span"
    if span_key in shape:
        return shape[span_key]
    return shape["wrapper_span"]


def source_admission(root):
    """Build the supervisor-owned S2 admission from independently reviewed bytes."""
    root = Path(root).resolve()
    directory = Path(__file__).parent
    root_key = key("root", ["project", "snapshot"])
    source_files = []
    source_anchors = []
    source_mappings = {}
    admitted_shapes = []
    for ordinal, shape in enumerate(baseline_shapes()):
        relative = shape["origin"]
        source = root / relative
        source.write_bytes((directory / relative).read_bytes())
        digest = hashlib.sha256(source.read_bytes()).hexdigest()
        file = key("file", [root_key, relative, digest])
        binding = _anchor_id(file, *shape["span"], "binding", [])
        source_files.append(["nx_files", [file, root_key, relative, digest, "project"]])
        source_anchors.append(["nx_anchors", [
            binding, file, *shape["span"], "binding", "[]",
        ]])
        wrappers = []
        for wrapper in shape["chain"]:
            start, end = _wrapper_span(shape, wrapper)
            anchor = _anchor_id(file, start, end, "apply", [ordinal])
            source_anchors.append(["nx_anchors", [
                anchor, file, start, end, "apply", canonical([ordinal]),
            ]])
            wrappers.append(anchor)
        source_mappings[str(source)] = file
        admitted_shapes.append({"binding": binding, "label": str(source), "wrappers": wrappers})
    return {
        "files": source_files,
        "anchors": source_anchors,
        "mappings": source_mappings,
        "shapes": admitted_shapes,
    }


def projection(ids, admitted_shapes=None):
    request, context = ids["request"], ids["context"]
    root = key("root", ["project", "source-content"])
    option = key("option", [context, '["demo","answer"]'])
    definition = key("definition", [request, option, "0"])
    facts = []

    def add(table, *args):
        facts.append([table, list(args)])

    def witness(kind, subject, state="observed"):
        observation = key("observation", [request, kind, subject])
        add("nx_observations", observation, request, "pre-apply-metadata", state)
        add("nx_observation_" + kind + "s", observation, subject)
        return observation

    add("nx_options", option, context, '["demo","answer"]')
    witness("option", option)
    add("nx_option_metadata", option, "isDefined", "true")
    add("nx_option_priority", option, "100")
    add("nx_definitions", definition, option, 0, key("origin", [request, "ordinary.nix"]))
    witness("definition", definition)

    for ordinal, shape in enumerate(baseline_shapes()):
        relative = shape["origin"]
        origin = key("origin", [request, relative])
        admitted = admitted_shapes[ordinal] if admitted_shapes is not None else None
        if admitted is None:
            file, binding = _anchor(root, relative, *shape["span"], "binding", [])
            label = relative
        else:
            file = None
            binding = admitted["binding"]
            label = admitted["label"]
        chain = []
        for index, wrapper in enumerate(shape["chain"]):
            if admitted is None:
                start, end = _wrapper_span(shape, wrapper)
                _, wrapper_anchor = _anchor(root, relative, start, end, "apply", [ordinal])
                add("nx_anchors", wrapper_anchor, file, start, end, "apply", canonical([ordinal]))
            else:
                wrapper_anchor = admitted["wrappers"][index]
            entry = {"kind": wrapper["kind"], "anchor": wrapper_anchor}
            entry.update({name: value for name, value in wrapper.items() if name != "kind"})
            chain.append(entry)
        candidate = key("candidate", [request, option, shape["module"], binding, "[]"])
        add("nx_origins", origin, label, "source")
        if admitted is None:
            add("nx_origin_files", origin, file)
            add("nx_files", file, root, relative, "source-content", "project")
            add("nx_anchors", binding, file, shape["span"][0], shape["span"][1], "binding", "[]")
            add("nx_target_inputs", ids["target"], file, "root")
        add("nx_candidates", candidate, option, ordinal, origin, binding,
            shape["active"], shape["selected"], canonical(chain))
        add("nx_definition_candidate_priorities", candidate, shape["priority"])
        witness("candidate", candidate)
        if shape["selected"] == "true":
            add("nx_definition_selections", candidate, definition)

    add("nx_request_results", request, "complete", "", 5)
    return {"protocolVersion": 1, "facts": facts}


def complete():
    ids = {kind: key(kind, ["all-definitions"]) for kind in
           ("context", "request", "run", "target")}
    packet = projection(ids)
    packet["facts"] += [
        ["nx_capabilities", [ids["target"], "all-definitions", "supported", ""]],
        ["nx_contexts", [ids["context"], ids["target"], "root", "[]"]],
        ["nx_requests", [ids["request"], ids["target"], ids["context"], "option-metadata",
                         '["demo","answer"]', "all-definitions", 0, 5, 1048576, 5, 256]],
        ["nx_runs", [ids["run"], "schema", "extractor", "grammar", "not-requested", "snapshot"]],
        ["nx_targets", [ids["target"], ids["run"], "D", "evalModules", "x86_64-linux",
                        "eval", "lib", "input", "policy", "complete"]],
    ]
    return packet
