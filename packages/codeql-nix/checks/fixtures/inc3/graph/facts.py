"""Contract-only M3g packets. No producer implementation is imported."""

import json


def key(kind, parts):
    return "nixql:v1:" + kind + ":" + "".join(str(len(part.encode())) + ":" + part for part in parts)


def rows(packet, relation):
    return [arguments for table, arguments in packet["facts"] if table == relation]


def projection(ids, empty=False):
    request, context = ids["request"], ids["context"]
    facts = []
    def add(table, *args):
        facts.append([table, list(args)])
    def witness(kind, subject):
        observation = key("observation", [request, kind, subject])
        add("nx_observations", observation, request, "pre-apply-metadata", "observed")
        add("nx_observation_" + kind + "s", observation, subject)
    witness("context", context)
    modules = {}
    if not empty:
        for path, name, label, disabled in (
            ([0], "root", "root.nix", False),
            ([0, 0], "child", "child.nix", True),
            ([0, 1], "child", "child.nix", True),
            ([1], ":anon-2", "<unknown-file>", False),
        ):
            path_json = json.dumps(path, separators=(",", ":"))
            module = key("module", [request, context, path_json])
            modules[tuple(path)] = module
            origin = key("origin", [request, path_json])
            add("nx_origins", origin, label, "synthetic")
            add("nx_modules", module, context, name, origin, disabled)
            witness("module", module)
            if len(path) == 1:
                add("nx_module_roots", context, path[0], module)
            else:
                add("nx_module_imports", modules[tuple(path[:-1])], path[-1], module)
    add("nx_request_results", request, "complete", "", 1 + len(modules))
    return {"protocolVersion": 1, "facts": facts}


def complete(empty=False):
    ids = {kind: key(kind, ["graph"]) for kind in ("context", "request", "run", "target")}
    packet = projection(ids, empty)
    packet["facts"] += [
        ["nx_capabilities", [ids["target"], "module-graph", "supported", ""]],
        ["nx_contexts", [ids["context"], ids["target"], "root", "[]"]],
        ["nx_requests", [ids["request"], ids["target"], ids["context"], "module-graph", "[]", "closure", 1, 5, 1048576, 5, 256]],
        ["nx_runs", [ids["run"], "schema", "extractor", "grammar", "not-requested", "snapshot"]],
        ["nx_targets", [ids["target"], ids["run"], "G", "evalModules", "x86_64-linux", "eval", "lib", "input", "policy", "complete"]],
    ]
    return packet
