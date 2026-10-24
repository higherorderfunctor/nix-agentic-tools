"""F1 expected data, transcribed from design sections 3–5 before implementation."""

from copy import deepcopy

# UTF-8 lengths count bytes; separators inside components are ordinary content.
KEYS = [
    ("file", [], "nixql:v1:file:"),
    ("file", [""], "nixql:v1:file:0:"),
    ("file", ["a:b", "é"], "nixql:v1:file:3:a:b2:é"),
    ("file", ["a", "b:c"], "nixql:v1:file:1:a3:b:c"),
    ("anchor", ["0", "0", "identifier", "[]"], "nixql:v1:anchor:1:01:010:identifier2:[]"),
]
PATHS = [
    ([], "[]"),
    (["a.b"], '["a.b"]'),
    (["a", "b"], '["a","b"]'),
    (["", "é", 'a"b', "a\\b", "\n"], '["","é","a\\"b","a\\\\b","\\n"]'),
]
PRIORITIES = ["-9223372036854775808", "-1", "0", "1", "9223372036854775807"]
BAD_PRIORITIES = [
    "", "-0", "-01", "-9223372036854775809", "+1", "00", "01", "1.0",
    "1e3", "9223372036854775808", " 1", "1\n", "١", 1, True, None,
]

# One-byte labels keep fixture identities independently readable.
I = {label: f"nixql:v1:{namespace}:1:{label}" for label, namespace in [
    ("a", "anchor"), ("c", "context"), ("d", "definition"), ("e", "diagnostic"),
    ("f", "file"), ("i", "observation"), ("j", "context"), ("k", "observation"), ("o", "option"),
    ("p", "origin"), ("q", "request"), ("r", "run"), ("t", "target"),
]}

# Step 0 relations; order needs the M3p same-request selection witness below.
PRIORITY_REQUEST = "nixql:v1:request:1:z"
ROOT = "nixql:v1:root:7:project9:content-a"
I["f"] = "nixql:v1:file:34:nixql:v1:root:7:project9:content-a11:fixture.nix9:content-a"
I["a"] = "nixql:v1:anchor:76:" + I["f"] + "1:01:010:identifier2:[]"

GRAPH = [
    ["nx_anchors", [I["a"], I["f"], 0, 0, "identifier", "[]"]],
    ["nx_capabilities", [I["t"], "metadata", "supported", ""]],
    ["nx_contexts", [I["c"], I["t"], "root", "[]"]],
    ["nx_contexts", [I["j"], I["t"], "root", "[]"]],
    ["nx_definitions", [I["d"], I["o"], 0, I["p"]]],
    ["nx_diagnostic_requests", [I["e"], I["q"]]],
    ["nx_diagnostic_targets", [I["e"], I["t"]]],
    ["nx_diagnostics", [I["e"], I["r"], "notice", "fixture"]],
    ["nx_files", [I["f"], ROOT, "fixture.nix", "content-a", "project"]],
    ["nx_observation_definitions", [I["k"], I["d"]]],
    ["nx_observation_options", [I["i"], I["o"]]],
    ["nx_observations", [I["i"], PRIORITY_REQUEST, "pre-apply-metadata", "observed"]],
    ["nx_observations", [I["k"], I["q"], "pre-apply-metadata", "observed"]],
    ["nx_option_declarations", [I["o"], 0, I["p"]]],
    ["nx_option_metadata", [I["o"], "isDefined", "true"]],
    ["nx_option_priority", [I["o"], "9223372036854775807"]],
    ["nx_options", [I["o"], I["c"], '["a.b"]']],
    ["nx_origin_files", [I["p"], I["f"]]],
    ["nx_origin_positions", [I["p"], 1, 1, "utf8-byte-1-based"]],
    ["nx_origins", [I["p"], "fixture.nix", "source"]],
    ["nx_phases", [I["r"], "discovery", "complete", ""]],
    ["nx_request_results", [I["q"], "complete", "", 3]],
    ["nx_request_results", [PRIORITY_REQUEST, "complete", "", 1]],
    ["nx_requests", [I["q"], I["t"], I["c"], "option-metadata", '["a.b"]', "declarations", 0, 10, 1048576, 5, 64]],
    ["nx_requests", [PRIORITY_REQUEST, I["t"], I["c"], "option-metadata", '["a.b"]', "priority", 0, 1, 1048576, 5, 64]],
    ["nx_runs", [I["r"], "schema", "extractor", "grammar", "not-requested", "snapshot-a"]],
    ["nx_syntax_results", [I["f"], "complete", 0]],
    ["nx_target_inputs", [I["t"], I["f"], "root"]],
    ["nx_targets", [I["t"], I["r"], "fixture", "evalModules", "x86_64-linux", "eval", "lib", "input", "policy", "complete"]],
]


# Independent M3p invocation witness over admitted function/formal structure.
# F1 validates supplied identity/structure; only the installed adapter tests
# authenticate these claims against actual source bytes and the supplied lib.
BINDING_GRAPH = deepcopy(GRAPH)
for relation, arguments in BINDING_GRAPH:
    if relation == "nx_requests" and arguments[0] == I["q"]:
        arguments[5] = "selection"
        arguments[6] = 1
    if relation == "nx_request_results" and arguments[0] == I["q"]:
        arguments[3] = 2
    if relation == "nx_runs":
        arguments[4] = "model-bundle"
FUNCTION = "nixql:v1:anchor:" + str(len(I["f"].encode())) + ":" + I["f"] + "1:02:1919:function_expression3:[0]"
FORMALS = "nixql:v1:anchor:" + str(len(I["f"].encode())) + ":" + I["f"] + "1:02:127:formals5:[0,0]"
FORMAL_NODE = "nixql:v1:anchor:" + str(len(I["f"].encode())) + ":" + I["f"] + "1:21:56:formal7:[0,0,0]"
FORMAL = "nixql:v1:anchor:" + str(len(I["f"].encode())) + ":" + I["f"] + "1:21:510:identifier9:[0,0,0,0]"
BINDING_OPTION_OBSERVATION = "nixql:v1:observation:1:s"
BINDING_GRAPH += [
    ["nx_definition_order", [I["d"], "-9223372036854775808"]],
    ["nx_observation_options", [BINDING_OPTION_OBSERVATION, I["o"]]],
    ["nx_observations", [BINDING_OPTION_OBSERVATION, I["q"], "pre-apply-metadata", "observed"]],
    ["nx_anchors", [FUNCTION, I["f"], 0, 19, "function_expression", "[0]"]],
    ["nx_anchors", [FORMALS, I["f"], 0, 12, "formals", "[0,0]"]],
    ["nx_anchors", [FORMAL_NODE, I["f"], 2, 5, "formal", "[0,0,0]"]],
    ["nx_anchors", [FORMAL, I["f"], 2, 5, "identifier", "[0,0,0,0]"]],
    ["nx_module_lib_bindings", [I["q"], FUNCTION, FORMAL, "lib", "model-bundle"]],
]

# Independent M3g closure witness over the second context: one module-graph
# request, its context witness, and a rooted two-occurrence import tree.
GRAPH_REQUEST = "nixql:v1:request:1:g"
MODULES = {label: f"nixql:v1:module:1:{label}" for label in "mn"}
GRAPH_ORIGINS = {label: f"nixql:v1:origin:1:{label}" for label in "wx"}
GRAPH_WITNESSES = {label: f"nixql:v1:observation:1:{label}" for label in "uvy"}
BINDING_GRAPH += [
    ["nx_module_imports", [MODULES["m"], 0, MODULES["n"]]],
    ["nx_module_roots", [I["j"], 0, MODULES["m"]]],
    ["nx_modules", [MODULES["m"], I["j"], "root", GRAPH_ORIGINS["w"], False]],
    ["nx_modules", [MODULES["n"], I["j"], "child", GRAPH_ORIGINS["x"], False]],
    ["nx_observation_contexts", [GRAPH_WITNESSES["y"], I["j"]]],
    ["nx_observation_modules", [GRAPH_WITNESSES["u"], MODULES["m"]]],
    ["nx_observation_modules", [GRAPH_WITNESSES["v"], MODULES["n"]]],
    ["nx_observations", [GRAPH_WITNESSES["u"], GRAPH_REQUEST, "pre-apply-metadata", "observed"]],
    ["nx_observations", [GRAPH_WITNESSES["v"], GRAPH_REQUEST, "pre-apply-metadata", "observed"]],
    ["nx_observations", [GRAPH_WITNESSES["y"], GRAPH_REQUEST, "pre-apply-metadata", "observed"]],
    ["nx_origins", [GRAPH_ORIGINS["w"], "root.nix", "synthetic"]],
    ["nx_origins", [GRAPH_ORIGINS["x"], "child.nix", "synthetic"]],
    ["nx_request_results", [GRAPH_REQUEST, "complete", "", 3]],
    ["nx_requests", [GRAPH_REQUEST, I["t"], I["j"], "module-graph", "[]", "closure", 1, 4, 1048576, 5, 64]],
]

# A second independently well-shaped literal function supplies the foreign-formal
# negative: an admitted lib formal is not interchangeable across functions.
def anchor_key(start, end, kind, child_path):
    parts = [I["f"], str(start), str(end), kind, child_path]
    return "nixql:v1:anchor:" + "".join(str(len(part.encode())) + ":" + part for part in parts)

FOREIGN_FUNCTION = anchor_key(20, 39, "function_expression", "[1]")
FOREIGN_FORMAL = anchor_key(22, 25, "identifier", "[1,0,0,0]")
FOREIGN_ANCHORS = [
    ["nx_anchors", [FOREIGN_FUNCTION, I["f"], 20, 39, "function_expression", "[1]"]],
    ["nx_anchors", [anchor_key(20, 32, "formals", "[1,0]"), I["f"], 20, 32, "formals", "[1,0]"]],
    ["nx_anchors", [anchor_key(22, 25, "formal", "[1,0,0]"), I["f"], 22, 25, "formal", "[1,0,0]"]],
    ["nx_anchors", [FOREIGN_FORMAL, I["f"], 22, 25, "identifier", "[1,0,0,0]"]],
]
