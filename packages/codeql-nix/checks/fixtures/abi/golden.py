"""F1 expected data, transcribed from design sections 3–5 before implementation."""

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
    ("a", "anchor"), ("b", "module"), ("h", "observation"), ("c", "context"), ("d", "definition"), ("e", "diagnostic"),
    ("f", "file"), ("i", "observation"), ("j", "context"), ("k", "observation"), ("l", "value"),
    ("m", "module"), ("n", "member"), ("o", "option"), ("p", "origin"),
    ("q", "request"), ("r", "run"), ("s", "value"), ("t", "target"),
    ("u", "observation"), ("v", "value"), ("w", "member"), ("x", "value"),
    ("y", "member"), ("z", "observation"),
]}

# All 35 handwritten relations, including successful null and equal-spelling path/string.
PRIORITY_REQUEST = "nixql:v1:request:1:z"
ROOT = "nixql:v1:root:7:project9:content-a"
I["f"] = "nixql:v1:file:34:nixql:v1:root:7:project9:content-a11:fixture.nix9:content-a"
I["a"] = "nixql:v1:anchor:76:" + I["f"] + "1:01:010:identifier2:[]"

GRAPH = [
    ["nx_anchors", [I["a"], I["f"], 0, 0, "identifier", "[]"]],
    ["nx_capabilities", [I["t"], "values", "supported", ""]],
    ["nx_context_parents", [I["j"], I["c"], I["o"], "attribute", "nested"]],
    ["nx_contexts", [I["c"], I["t"], "root", "[]"]],
    ["nx_contexts", [I["j"], I["t"], "concrete-submodule", '["nested"]']],
    ["nx_definition_order", [I["d"], "-9223372036854775808"]],
    ["nx_definitions", [I["d"], I["o"], 0, I["p"]]],
    ["nx_diagnostic_origins", [I["e"], I["p"]]],
    ["nx_diagnostic_requests", [I["e"], I["q"]]],
    ["nx_diagnostic_targets", [I["e"], I["t"]]],
    ["nx_diagnostics", [I["e"], I["r"], "notice", "fixture"]],
    ["nx_files", [I["f"], ROOT, "fixture.nix", "content-a", "project"]],
    ["nx_member_values", [I["n"], I["s"]]],
    ["nx_member_values", [I["w"], I["x"]]],
    ["nx_member_values", [I["y"], I["l"]]],
    ["nx_module_imports", [I["m"], 0, I["b"]]],
    ["nx_module_roots", [I["c"], 0, I["m"]]],
    ["nx_modules", [I["b"], I["c"], "fixture", I["p"], 1]],
    ["nx_modules", [I["m"], I["c"], "fixture", I["p"], 0]],
    ["nx_observation_values", [I["h"], I["l"]]],
    ["nx_observation_values", [I["k"], I["v"]]],
    ["nx_observation_values", [I["u"], I["s"]]],
    ["nx_observation_values", [I["z"], I["x"]]],
    ["nx_observations", [I["h"], I["q"], "member", I["y"], "applied-config", "observed"]],
    ["nx_observations", [I["i"], PRIORITY_REQUEST, "option", I["o"], "pre-apply-metadata", "observed"]],
    ["nx_observations", [I["k"], I["q"], "option", I["o"], "applied-config", "observed"]],
    ["nx_observations", [I["u"], I["q"], "member", I["n"], "applied-config", "observed"]],
    ["nx_observations", [I["z"], I["q"], "member", I["w"], "applied-config", "observed"]],
    ["nx_option_declarations", [I["o"], 0, I["p"]]],
    ["nx_option_metadata", [I["o"], "isDefined", "true"]],
    ["nx_option_metadata", [I["o"], "visible", '"shallow"']],
    ["nx_option_priority", [I["o"], "9223372036854775807"]],
    ["nx_options", [I["o"], I["c"], '["a.b"]']],
    ["nx_origin_files", [I["p"], I["f"]]],
    ["nx_origin_positions", [I["p"], 1, 1, "utf8-byte-1-based"]],
    ["nx_origins", [I["p"], "fixture.nix", "source"]],
    ["nx_phases", [I["r"], "discovery", "complete", ""]],
    ["nx_request_results", [I["q"], "complete", "", 3]],
    ["nx_request_results", [PRIORITY_REQUEST, "complete", "", 1]],
    ["nx_requests", [I["q"], I["t"], I["c"], "option-value", '["a.b"]', "value", 3, 10, 1048576, 5, 64]],
    ["nx_requests", [PRIORITY_REQUEST, I["t"], I["c"], "option-metadata", '["a.b"]', "priority", 0, 1, 1048576, 5, 64]],
    ["nx_runs", [I["r"], "schema", "extractor", "grammar", "model", "snapshot-a"]],
    ["nx_scalar_values", [I["s"], "evaluated-path-json-v1", '"/work/é/../alias"']],
    ["nx_scalar_values", [I["x"], "string-json-v1", '"/work/é/../alias"']],
    ["nx_scalar_values", [I["l"], "null-json-v1", "null"]],
    ["nx_string_context", [I["x"], "/nix/store/example", "opaque", ""]],
    ["nx_syntax_results", [I["f"], "complete", 0]],
    ["nx_target_inputs", [I["t"], I["f"], "root"]],
    ["nx_targets", [I["t"], I["r"], "fixture", "evalModules", "x86_64-linux", "eval", "lib", "input", "policy", "complete"]],
    ["nx_value_members", [I["n"], I["v"], "list", "0", 0]],
    ["nx_value_members", [I["w"], I["v"], "list", "1", 1]],
    ["nx_value_members", [I["y"], I["v"], "list", "2", 2]],
    ["nx_values", [I["l"], "null", "complete"]],
    ["nx_values", [I["s"], "path", "complete"]],
    ["nx_values", [I["v"], "list", "complete"]],
    ["nx_values", [I["x"], "string", "complete"]],
]
