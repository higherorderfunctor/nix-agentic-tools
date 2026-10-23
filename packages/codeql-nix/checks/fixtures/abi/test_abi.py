"""Execute F1 ABI behavior against a supplied module; expectations predate code."""

from copy import deepcopy
import importlib.util
import json
from pathlib import Path
import re
import sys
import unittest

from golden import BAD_PRIORITIES, GRAPH, I, KEYS, PATHS, PRIORITIES, PRIORITY_REQUEST, ROOT

MODULE = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[3] / "schema/abi.py"
spec = importlib.util.spec_from_file_location("abi", MODULE)
abi = importlib.util.module_from_spec(spec)
spec.loader.exec_module(abi)
LIMIT = 1048576
STEP0_TABLES = {
    "nx_anchors", "nx_capabilities", "nx_contexts", "nx_definitions",
    "nx_diagnostic_requests", "nx_diagnostic_targets", "nx_diagnostics", "nx_files",
    "nx_observation_definitions", "nx_observation_options", "nx_observations",
    "nx_option_declarations", "nx_option_metadata",
    "nx_option_priority", "nx_options", "nx_origin_files", "nx_origin_positions",
    "nx_origins", "nx_phases", "nx_request_results", "nx_requests", "nx_runs",
    "nx_syntax_results", "nx_target_inputs", "nx_targets",
}


def row(rows, name, occurrence=0):
    return [arguments for table, arguments in rows if table == name][occurrence]


class AbiTests(unittest.TestCase):
    def rejects(self, table, column, value, occurrence=0):
        rows = deepcopy(GRAPH)
        row(rows, table, occurrence)[column] = value
        with self.assertRaises(ValueError, msg=f"{table}[{column}]={str(value)[:80]}"):
            abi.validate(rows)

    def test_serialization_examples(self):
        for namespace, parts, expected in KEYS:
            self.assertEqual(abi.key(namespace, parts), expected)
        for segments, expected in PATHS:
            self.assertEqual(abi.path(segments), expected)
        for text in PRIORITIES:
            self.assertEqual(abi.priority(text), text)
        self.assertNotEqual(abi.key("file", ["é"]), abi.key("file", ["e\u0301"]))
        self.assertNotEqual(abi.key("file", ["a", "bc"]), abi.key("file", ["ab", "c"]))
        self.assertNotEqual(abi.key("file", ["a"]), abi.key("anchor", ["a"]))
        for namespace in ("", "bad:namespace", "Upper", "file\n"):
            with self.assertRaises(ValueError):
                abi.key(namespace, ["a"])
        for value in BAD_PRIORITIES:
            with self.assertRaises(ValueError, msg=repr(value)):
                abi.priority(value)
        for value in ("a.b", [1], [True], [None]):
            with self.assertRaises(ValueError):
                abi.path(value)

    def test_source_anchor_and_evaluation_identity_components(self):
        self.assertEqual(abi.key("root", ["project", "content-a"]), ROOT)
        self.assertEqual(abi.key("file", [ROOT, "fixture.nix", "content-a"]), I["f"])
        self.assertEqual(abi.key("anchor", [I["f"], "0", "0", "identifier", "[]"]), I["a"])
        # Independent component changes alter identity; moving a worktree does not enter it.
        root_parts = ["project", "content-a"]
        for index in range(2):
            changed = root_parts.copy()
            changed[index] += "-changed"
            self.assertNotEqual(abi.key("root", changed), ROOT)
        file_parts = [ROOT, "fixture.nix", "content-a"]
        for index in range(3):
            changed = file_parts.copy()
            changed[index] += "-changed"
            self.assertNotEqual(abi.key("file", changed), I["f"])
        for kind, child_path in (("binding", "[]"), ("identifier", "[0]"), ("identifier", "[1,0]")):
            self.assertNotEqual(abi.key("anchor", [I["f"], "0", "0", kind, child_path]), I["a"])
        components = ["eval-v1", "lib-v1", "adapter-v1", "model-v1", "args-v1", "snapshot-a", "policy-a", "x86_64-linux"]
        identity = abi.key("target", components)
        for index in range(len(components)):
            changed = components.copy()
            changed[index] += "-changed"
            self.assertNotEqual(abi.key("target", changed), identity)
        self.rejects("nx_files", 3, "different-content")
        self.rejects("nx_anchors", 4, "binding")
        self.rejects("nx_anchors", 5, "[0]")

    def test_complete_graph_and_schema_inventory(self):
        before = deepcopy(GRAPH)
        abi.validate(GRAPH)
        abi.validate(list(reversed(GRAPH)))
        self.assertEqual(GRAPH, before)
        tables = {name for name, _ in GRAPH}
        self.assertEqual(tables, STEP0_TABLES)
        self.assertEqual(set(abi.COLUMNS), STEP0_TABLES)
        schema = MODULE.with_name("evaluation.dbscheme").read_text()
        self.assertEqual(set(re.findall(r"(?m)^(nx_\w+)\s*\(", schema)), tables)

    def test_arity_types_unique_keys_and_foreign_relations(self):
        for name, arguments in GRAPH:
            with self.subTest(table=name):
                with self.assertRaises(ValueError):
                    abi.validate(deepcopy(GRAPH) + [[name, deepcopy(arguments)]])
                self.rejects(name, 0, "nixql:v1:unknown:1:x")
        with self.assertRaises(ValueError):
            abi.validate([["nx_not_a_table", []]])
        with self.assertRaises(ValueError):
            abi.validate([["nx_runs", []]])
        self.rejects("nx_anchors", 1, I["q"])
        self.rejects("nx_definitions", 2, -1)
        self.rejects("nx_request_results", 3, True)
        self.rejects("nx_anchors", 3, -1)
        self.rejects("nx_origin_positions", 1, 0)
        rows = deepcopy(GRAPH) + [["nx_definitions", ["nixql:v1:definition:1:2", I["o"], 0, I["p"]]]]
        with self.assertRaisesRegex(ValueError, "duplicate definition ordinal"):
            abi.validate(rows)

    def test_same_namespace_dangling_foreign_references(self):
        for name, _ in GRAPH:
            for column, (_, kind) in enumerate(abi.COLUMNS[name]):
                if kind not in abi.CONTRACT["entities"] or (column == 0 and name == f"nx_{kind}s"):
                    continue
                with self.subTest(table=name, column=column):
                    self.rejects(name, column, f"nixql:v1:{kind}:7:missing")

    def test_enum_and_subject_rules(self):
        fields = {"nx_capabilities": 2, "nx_contexts": 2, "nx_origins": 2,
                  "nx_phases": 2, "nx_request_results": 1, "nx_requests": 3,
                  "nx_syntax_results": 1, "nx_targets": 9}
        for name, column in fields.items():
            self.rejects(name, column, "bogus")
        for column in (2, 3):
            self.rejects("nx_observations", column, "bogus")
        self.rejects("nx_observation_options", 1, I["q"])
        self.rejects("nx_options", 2, '["a", "b"]')  # Whitespace is not canonical.
        self.rejects("nx_options", 2, '[1]')
        self.rejects("nx_option_metadata", 1, "description")
        self.rejects("nx_option_priority", 1, "-0")
        self.rejects("nx_option_priority", 1, "9223372036854775808")
        self.rejects("nx_contexts", 2, "concrete-submodule")
        self.rejects("nx_contexts", 3, '["nested"]')
        self.rejects("nx_contexts", 3, '[0]')

    def test_observation_target_and_context_are_not_interchangeable(self):
        self.rejects("nx_options", 1, I["j"])
        rows = deepcopy(GRAPH)
        other = "nixql:v1:target:1:2"
        target = deepcopy(row(rows, "nx_targets"))
        target[0] = other
        rows.append(["nx_targets", target])
        row(rows, "nx_requests")[1] = other
        with self.assertRaises(ValueError):
            abi.validate(rows)

    def test_origin_cannot_cross_source_snapshots(self):
        rows = deepcopy(GRAPH)
        other_file, other_run, other_target = [f"nixql:v1:{ns}:1:2" for ns in ("file", "run", "target")]
        file = deepcopy(row(rows, "nx_files"))
        other_file = "nixql:v1:file:34:nixql:v1:root:7:project9:content-b11:fixture.nix9:content-b"
        file[0], file[1], file[3] = other_file, "nixql:v1:root:7:project9:content-b", "content-b"
        run = deepcopy(row(rows, "nx_runs"))
        run[0], run[-1] = other_run, "snapshot-b"
        target = deepcopy(row(rows, "nx_targets"))
        target[0], target[1] = other_target, other_run
        rows.extend([["nx_files", file], ["nx_runs", run], ["nx_targets", target],
                     ["nx_target_inputs", [other_target, other_file, "root"]]])
        row(rows, "nx_origin_files")[1] = other_file
        with self.assertRaises(ValueError):
            abi.validate(rows)

    def test_completion_does_not_survive_refusal(self):
        for reason in ("timeout", "text-field-too-large"):
            self.rejects("nx_request_results", 2, reason)
        self.rejects("nx_request_results", 1, "unsupported", 1)
        self.rejects("nx_observations", 3, "unforced")
        self.rejects("nx_observations", 3, "failed")
        rows = [deepcopy(item) for item in GRAPH if item[0] in {
            "nx_contexts", "nx_phases", "nx_request_results", "nx_requests", "nx_runs", "nx_targets"}]
        rows = [item for item in rows if not (item[0] == "nx_contexts" and item[1][0] == I["j"])]
        row(rows, "nx_request_results")[1:4] = ["unsupported", "text-field-too-large", 0]
        abi.validate(rows)
        # A failed discovery can be represented before any target exists.
        abi.validate([["nx_runs", deepcopy(row(GRAPH, "nx_runs"))],
                      ["nx_phases", [I["r"], "target-discovery", "failed", "manifest-error"]]])

    def test_winning_priority_requires_its_own_defined_metadata_observation(self):
        # A priority witness is independent of values and other metadata requests.
        def priority_rows():
            return [deepcopy(item) for item in GRAPH if item[0] in {
                "nx_contexts", "nx_options", "nx_option_metadata", "nx_option_priority",
                "nx_requests", "nx_request_results", "nx_observation_options", "nx_observations", "nx_runs", "nx_targets"
            } and (item[0] != "nx_observations" or item[1][0] == I["i"])]

        for state in ("complete", "partial"):
            rows = priority_rows()
            row(rows, "nx_request_results", 1)[1] = state
            abi.validate(rows)  # No value association is necessary for metadata.
        for payload in ("false", "null", '"true"', "1"):
            rows = priority_rows()
            row(rows, "nx_option_metadata")[2] = payload
            with self.assertRaisesRegex(ValueError, "option priority lacks defined observation"):
                abi.validate(rows)
        for table in ("nx_option_metadata", "nx_observations"):
            rows = [item for item in priority_rows() if item[0] != table
                    and not (table == "nx_observations" and item[0] == "nx_observation_options")]
            with self.assertRaisesRegex(ValueError, "option priority lacks defined observation"):
                abi.validate(rows)
        for table, column, value in (
            ("nx_requests", 4, '["a","b"]'),
            ("nx_requests", 5, "value"),
            ("nx_observations", 3, "unforced"),
            ("nx_observations", 3, "failed"),
        ):
            with self.subTest(table=table, column=column, value=value):
                rows = priority_rows()
                row(rows, table, 1 if table == "nx_requests" else 0)[column] = value
                with self.assertRaisesRegex(ValueError, "option priority lacks defined observation"):
                    abi.validate(rows)
        for state in ("blocked", "failed", "skipped", "unsupported", None):
            rows = priority_rows()
            rows = [item for item in rows if not (item[0] == "nx_request_results" and item[1][0] == PRIORITY_REQUEST)]
            if state is not None:
                rows.append(["nx_request_results", [PRIORITY_REQUEST, state, "", 0]])
            with self.assertRaisesRegex(ValueError, "observation from unsuccessful projection"):
                abi.validate(rows)
        # A different option, including one with the same path in another context,
        # cannot supply the witness even though that observation is valid itself.
        for context in (I["c"], I["j"]):
            rows = priority_rows()
            other = "nixql:v1:option:1:2"
            rows.append(["nx_options", [other, context, '["a.b"]']])
            row(rows, "nx_observation_options")[1] = other
            row(rows, "nx_requests", 1)[2] = context
            with self.assertRaisesRegex(ValueError, "option priority lacks defined observation"):
                abi.validate(rows)
        rows = [deepcopy(item) for item in GRAPH if not (item[0] in {"nx_observation_options", "nx_observations"} and item[1][0] == I["i"])]
        with self.assertRaisesRegex(ValueError, "option priority lacks defined observation"):
            abi.validate(rows)  # Other metadata requests prove no priority.

    def test_exact_text_utf8_boundaries_and_escaping(self):
        for size in (LIMIT - 1, LIMIT, LIMIT + 1):
            texts = ["x" * size, "é" * (size // 2) + "x" * (size % 2), '"' * size]
            for text in texts:
                self.assertEqual(len(text.encode("utf-8")), size)
                rows = deepcopy(GRAPH)
                row(rows, "nx_origins")[1] = text
                if size <= LIMIT:
                    abi.validate(rows)
                    self.assertEqual(row(rows, "nx_origins")[1], text)
                else:
                    with self.assertRaises(ValueError):
                        abi.validate(rows)
            # Encoded path adds four ASCII bytes: ["..."] before TRAP quoting.
            for character, overhead in (("x", 4), ('"', 4)):
                count = (size - overhead) // (2 if character == '"' else 1)
                encoded = json.dumps([character * count + "x" * ((size - overhead) % (2 if character == '"' else 1))], ensure_ascii=False, separators=(",", ":"))
                self.assertEqual(len(encoded.encode("utf-8")), size)
                rows = deepcopy(GRAPH)
                row(rows, "nx_options")[2] = encoded
                for table, arguments in rows:
                    if table == "nx_requests":
                        arguments[4] = encoded
                if size <= LIMIT:
                    abi.validate(rows)
                else:
                    with self.assertRaises(ValueError):
                        abi.validate(rows)

    def test_global_keys_remain_unbounded_through_typed_links(self):
        huge = abi.key("option", ["x" * (LIMIT + 1)])
        rows = deepcopy(GRAPH)
        for _, arguments in rows:
            arguments[:] = [huge if value == I["o"] else value for value in arguments]
        abi.validate(rows)  # Typed entity links do not repeat identity in bounded text.


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
