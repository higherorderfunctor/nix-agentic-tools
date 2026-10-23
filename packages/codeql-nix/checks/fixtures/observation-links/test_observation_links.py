"""X1 contract-first identity witnesses; expected subjects never come from code."""

from copy import deepcopy
from pathlib import Path
import re
import sys
import tempfile
import unittest

OWNER = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(OWNER / "src/eval"))
from protocol import abi, envelope, trap
from supervisor import projection_rows, publish

# Independent one-byte entity labels; none encode an option path or ordinal.
I = {name: f"nixql:v1:{kind}:1:{name}" for name, kind in (
    ("a", "option"), ("b", "option"), ("c", "context"), ("d", "definition"),
    ("e", "definition"), ("i", "observation"), ("j", "context"),
    ("p", "origin"), ("q", "request"), ("r", "run"), ("t", "target"),
    ("u", "target"))}
LINKS = {"definition": "nx_observation_definitions", "option": "nx_observation_options"}
BASE = [
    ["nx_runs", [I["r"], "schema", "extractor", "grammar", "not-requested", "snapshot"]],
    ["nx_targets", [I["t"], I["r"], "fixture", "evalModules", "x86_64-linux", "eval", "lib", "inputs", "policy", "complete"]],
    ["nx_contexts", [I["c"], I["t"], "root", "[]"]],
    ["nx_requests", [I["q"], I["t"], I["c"], "option-metadata", '["requested"]', "declarations", 0, 10, 4096, 5, 64]],
    ["nx_request_results", [I["q"], "complete", "", 1]],
    ["nx_options", [I["a"], I["c"], '["a"]']],
    ["nx_options", [I["b"], I["c"], '["b"]']],
    ["nx_origins", [I["p"], "fixture.nix", "synthetic"]],
    ["nx_definitions", [I["d"], I["a"], 0, I["p"]]],
    ["nx_definitions", [I["e"], I["a"], 1, I["p"]]],
    ["nx_observations", [I["i"], I["q"], "pre-apply-metadata", "observed"]],
]


def graph(kind="option", subject="a"):
    return deepcopy(BASE) + [[LINKS[kind], [I["i"], I[subject]]]]


def row(facts, name):
    return next(args for relation, args in facts if relation == name)


def subjects(rendered, relation):
    """Read typed TRAP references independently, without the production schema."""
    labels = dict(re.findall(r'(?m)^(#\d+)=@"([^"]+)"$', rendered))
    return [(labels[left], labels[right]) for left, right in
            re.findall(r'(?m)^' + relation + r'\((#\d+),\s*(#\d+)\)$', rendered)]


class ObservationLinkTests(unittest.TestCase):
    def accepts(self, facts):
        before = deepcopy(facts)
        self.assertEqual(envelope(facts), {"protocolVersion": 1, "facts": before})
        abi.validate(list(reversed(facts)))
        self.assertEqual(facts, before)

    def rejects(self, facts):
        with self.assertRaises(ValueError):
            envelope(facts)

    def test_option_worlds_keep_different_subject_paths_despite_same_request(self):
        worlds = [graph(subject=subject) for subject in ("a", "b")]
        self.assertEqual(worlds[0][:-1], worlds[1][:-1])
        for facts, expected in zip(worlds, ('["a"]', '["b"]')):
            self.accepts(facts)
            pairs = subjects(trap(facts), LINKS["option"])
            self.assertEqual(pairs, [(I["i"], I["a"] if expected == '["a"]' else I["b"])])
            paths = {args[0]: args[2] for table, args in facts if table == "nx_options"}
            self.assertEqual([paths[subject] for _, subject in pairs], [expected])
            self.assertNotEqual(row(facts, "nx_requests")[4], expected)
        self.rejects(deepcopy(BASE))  # The indistinguishable old worlds are invalid.

    def test_definition_worlds_identify_only_one_observed_sibling(self):
        worlds = [graph("definition", subject) for subject in ("d", "e")]
        self.assertEqual(worlds[0][:-1], worlds[1][:-1])
        for facts, expected in zip(worlds, (0, 1)):
            self.accepts(facts)
            pairs = subjects(trap(facts), LINKS["definition"])
            ordinals = {args[0]: args[2] for table, args in facts if table == "nx_definitions"}
            self.assertEqual([ordinals[subject] for _, subject in pairs], [expected])
            self.assertEqual(len(pairs), 1)  # Its sibling's metadata proves no observation.
        self.rejects(deepcopy(BASE))

    def test_every_observation_state_requires_one_subject(self):
        for state in ("blocked", "failed", "observed", "unforced", "unsupported"):
            for kind, subject in (("option", "a"), ("definition", "d")):
                with self.subTest(state=state, kind=kind):
                    facts = graph(kind, subject)
                    row(facts, "nx_observations")[-1] = state
                    self.accepts(facts)
                    self.rejects(facts[:-1])

    def test_multiple_same_kind_or_mixed_links_are_rejected(self):
        self.accepts(graph())
        self.accepts(graph("definition", "d"))
        for first, subject, second, other in (
            ("option", "a", "option", "b"), ("definition", "d", "definition", "e"),
            ("option", "a", "definition", "d"), ("definition", "d", "option", "a"),
        ):
            facts = graph(first, subject)
            self.rejects(facts + [[LINKS[second], [I["i"], I[other]]]])
            self.rejects(facts + [deepcopy(facts[-1])])

    def test_links_are_typed_and_foreign_references_must_exist(self):
        self.accepts(graph())
        self.accepts(graph("definition", "d"))
        for kind, subject in (("option", "a"), ("definition", "d")):
            for column, value in ((0, "nixql:v1:observation:7:missing"),
                                  (0, I["q"]), (1, f"nixql:v1:{kind}:7:missing"),
                                  (1, I["q"])):
                with self.subTest(kind=kind, column=column, value=value):
                    facts = graph(kind, subject)
                    facts[-1][1][column] = value
                    self.rejects(facts)

    def test_subject_scope_cannot_cross_context_or_target(self):
        self.accepts(graph())
        self.accepts(graph("definition", "d"))
        for kind, subject in (("option", "a"), ("definition", "d")):
            for target in ("t", "u"):
                with self.subTest(kind=kind, target=target):
                    facts = graph(kind, subject)
                    if target == "u":
                        foreign = deepcopy(row(facts, "nx_targets"))
                        foreign[0] = I["u"]
                        facts.append(["nx_targets", foreign])
                    facts.append(["nx_contexts", [I["j"], I[target], "root", "[]"]])
                    row(facts, "nx_options")[1] = I["j"]
                    self.rejects(facts)

    def test_observed_link_still_requires_successful_request(self):
        self.accepts(graph())
        self.accepts(graph("definition", "d"))
        for kind, subject in (("option", "a"), ("definition", "d")):
            for state in ("blocked", "failed", "skipped", "unsupported"):
                facts = graph(kind, subject)
                row(facts, "nx_request_results")[1:4] = [state, "fixture-refusal", 0]
                self.rejects(facts)

    def test_supervisor_validates_and_publishes_option_link(self):
        facts = graph()
        row(facts, "nx_requests")[4] = '["a"]'
        outer = [item for item in facts if item[0] in {"nx_runs", "nx_targets", "nx_contexts", "nx_requests"}]
        projection = [item for item in facts if item[0] in {"nx_options", "nx_observations", "nx_observation_options", "nx_request_results"}
                      and not (item[0] == "nx_options" and item[1][0] == I["b"])]
        job = {"identities": {"request": I["q"], "context": I["c"]},
               "request": {"path": ["a"], "facet": "declarations", "maxNodes": 10}}
        accepted, state = projection_rows({"protocolVersion": 1, "facts": projection}, job, outer)
        self.assertEqual(state, "complete")
        self.assertEqual(accepted, projection)
        with tempfile.TemporaryDirectory() as directory:
            publish(Path(directory), "fixture", accepted)
            self.assertEqual([path.name for path in Path(directory).iterdir()], ["fixture.trap"])
            self.assertEqual(subjects((Path(directory) / "fixture.trap").read_text(), LINKS["option"]), [(I["i"], I["a"])])
        for invalid in (projection[:-1], projection + [[LINKS["option"], [I["i"], I["b"]]]]):
            with self.assertRaises(ValueError):
                projection_rows({"protocolVersion": 1, "facts": invalid}, job, outer)


if __name__ == "__main__":
    unittest.main(verbosity=2)
