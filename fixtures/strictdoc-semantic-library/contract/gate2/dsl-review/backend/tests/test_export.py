"""Tests for the StrictDoc export to candidate mapping.

Two layers. The mapping tests build an export document inline, so they run
anywhere and they pin one rule each. The end to end tests run the real
``export-candidate.sh`` against the real corpus and compare its output with the
delivered ``candidate.json``, once from the project root and once from the
documents directory inside it, and they pin the refusal when no ancestor of the
named directory is a StrictDoc project. Those need ``strictdoc``, so they skip
with a message naming the shell that provides it. ``run-fixtures.sh`` enters
that shell itself when ``strictdoc`` is absent, so the skip is what a run
outside the fixture reports, not what a normal run reports.

Comparison is between decoded objects, which is exactly the contract's
normalized comparison: object member order and insignificant whitespace do not
affect it, while array order does (contract.md:633-634). Nothing here compares
text, so the checked in candidate may be formatted however it likes.
"""

import copy
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

TESTS_DIRECTORY = pathlib.Path(__file__).resolve().parent
BACKEND_DIRECTORY = TESTS_DIRECTORY.parent
PACKET_DIRECTORY = BACKEND_DIRECTORY.parent
FIXTURE_ROOT = BACKEND_DIRECTORY.parents[3]
EXPORT_SCRIPT = BACKEND_DIRECTORY / "export-candidate.sh"

if str(BACKEND_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(BACKEND_DIRECTORY))

from sdoc_semantics import export  # noqa: E402  (needs the path entry above)

SHELL_MESSAGE = (
    "strictdoc is not on PATH, so no export can be produced. Run the suite "
    "inside the fixture shell: cd %s && devenv shell -- "
    "contract/gate2/dsl-review/backend/run-fixtures.sh" % FIXTURE_ROOT
)

# One element, two declared fields, one parent relation and one child relation.
# AUTHORED_BY is deliberately absent: the export grammar below declares it and
# the bundle does not, which is how a native runtime field is told apart from a
# defect.
SAMPLE_BUNDLE = {
    "bundle": {
        "declarations": [
            {"id": "model:sample", "kind": "model", "name": "sample"},
            {"id": "model:sample/element:ITEM", "kind": "element", "name": "ITEM"},
        ]
    },
    "grammar": [
        {
            "tag": "ITEM",
            "fields": [
                {"string": {"required": True, "title": "UID"}},
                {"singleChoice": {"choices": ["low", "high"], "title": "LABEL"}},
            ],
            "relations": [
                {"parent": {"role": "K", "reverseRole": "K_back"}},
                {"child": {"role": "L", "reverseRole": "L_back"}},
            ],
        }
    ],
}

SAMPLE_GRAMMAR = {
    "ELEMENTS": [
        {
            "NODE_TYPE": "TEXT",
            "FIELDS": [{"TITLE": "STATEMENT", "TYPE": "String"}],
            "RELATIONS": [],
        },
        {
            "NODE_TYPE": "ITEM",
            "FIELDS": [
                {"TITLE": "AUTHORED_BY", "TYPE": "String"},
                {"TITLE": "UID", "TYPE": "String"},
                {"TITLE": "LABEL", "TYPE": "String"},
            ],
            "RELATIONS": [{"TYPE": "Parent", "ROLE": "K"}],
        },
    ]
}


def bundle_declaring_authored_by(bundle, tag):
    """Return a copy of a bundle whose element also declares AUTHORED_BY.

    AUTHORED_BY is the corpus's block-form field, and no bundle in the packet
    declares it, so a bundle that does is the only way to watch its value reach
    a candidate.
    """
    widened = copy.deepcopy(bundle)
    for entry in widened["grammar"]:
        if entry["tag"] == tag:
            entry["fields"].insert(
                0, {"string": {"required": True, "title": "AUTHORED_BY"}}
            )
    return widened


def one_document(nodes, title="Sample"):
    """Return a decoded export holding one document with these nodes."""
    return {
        "DOCUMENTS": [
            {
                "_NODE_TYPE": "DOCUMENT",
                "TITLE": title,
                "GRAMMAR": SAMPLE_GRAMMAR,
                "NODES": nodes,
            }
        ]
    }


def item(uid, **rest):
    """Return one ITEM node carrying the metadata the export always emits."""
    node = {"_TOC": "", "_NODE_TYPE": "ITEM", "AUTHORED_BY": "llm\n", "UID": uid}
    node.update(rest)
    return node


class MappingTest(unittest.TestCase):
    def test_the_export_maps_onto_the_contract_record_shape(self):
        """One pass over every mapping rule that keeps a node or drops a key.

        A TEXT node carries no record. A file relation names a path rather than
        a uid, so it is not an occurrence. A duplicate identical occurrence is
        kept as authored (contract.md:499-500). AUTHORED_BY is native only, so
        the candidate never carries it. Fields come out in the bundle's grammar
        order and each value is a one-item list of the native string
        (contract.md:493-494).
        """
        produced = export.candidate_from_export(
            one_document(
                [
                    {"_NODE_TYPE": "TEXT", "STATEMENT": "Prose, not a record."},
                    item(
                        "A1",
                        LABEL="high",
                        RELATIONS=[
                            {"TYPE": "Parent", "ROLE": "K", "VALUE": "A0"},
                            {"TYPE": "Parent", "ROLE": "K", "VALUE": "A0"},
                            {"TYPE": "File", "VALUE": "docs/note.md"},
                            {"TYPE": "Child", "ROLE": "L", "VALUE": "A2"},
                        ],
                    ),
                    item("A2"),
                ]
            ),
            SAMPLE_BUNDLE,
        )
        self.assertEqual(
            produced,
            {
                "model": "sample",
                "records": [
                    {
                        "uid": "A1",
                        "element": "ITEM",
                        "fields": {"UID": ["A1"], "LABEL": ["high"]},
                        "relations": [
                            {"role": "K", "direction": "parent", "target": "A0"},
                            {"role": "K", "direction": "parent", "target": "A0"},
                            {"role": "L", "direction": "child", "target": "A2"},
                        ],
                    },
                    {
                        "uid": "A2",
                        "element": "ITEM",
                        "fields": {"UID": ["A2"]},
                        "relations": [],
                    },
                ],
                "created": [],
            },
        )

    def test_a_block_form_field_keeps_its_trailing_newline(self):
        """StrictDoc's block form encloses newlines, and they are the value.

        The corpus authors AUTHORED_BY as ``>>>\nllm\n<<<``, which StrictDoc
        reports as ``"llm\n"``. The mapping passes that through, because the
        contract asks for the string exactly as authored
        (contract.md:490-491). field-value compares native strings exactly
        (contract.md:308-309), so a leaf naming ``llm`` matches no record
        carrying this field. Trimming here would make the exporter disagree
        with StrictDoc's own parse and would break preserve's byte comparison,
        so the newline stays and this test says so out loud.
        """
        produced = export.candidate_from_export(
            one_document([item("A1")]),
            bundle_declaring_authored_by(SAMPLE_BUNDLE, "ITEM"),
        )
        fields = produced["records"][0]["fields"]
        self.assertEqual(fields["AUTHORED_BY"], ["llm\n"])
        self.assertNotEqual(fields["AUTHORED_BY"], ["llm"])

    def test_a_file_relation_declaration_is_dropped_not_rejected(self):
        """A File relation declares no owned occurrence, so it is dropped.

        ``rel.file`` lowers to ``{"file": {}}`` in the native grammar, and any
        ordinary .sgra can express it. It names a path rather than a record, so
        it declares no role and no direction. Dropping the declaration is the
        same policy the occurrence mapping already applies, so a grammar
        carrying one still exports every record.
        """
        bundle = copy.deepcopy(SAMPLE_BUNDLE)
        bundle["grammar"][0]["relations"].append({"file": {}})
        elements = export.semantic_elements(bundle)
        self.assertEqual(
            elements["ITEM"]["occurrences"], {("parent", "K"), ("child", "L")}
        )
        produced = export.candidate_from_export(
            one_document([item("A1", LABEL="low")]), bundle
        )
        self.assertEqual([record["uid"] for record in produced["records"]], ["A1"])

    def test_a_node_beneath_a_section_is_collected(self):
        """The walk descends, so a nested record is never dropped silently."""
        produced = export.candidate_from_export(
            one_document(
                [
                    {
                        "_NODE_TYPE": "SECTION",
                        "TITLE": "Group",
                        "NODES": [item("A1")],
                    }
                ]
            ),
            SAMPLE_BUNDLE,
        )
        self.assertEqual([record["uid"] for record in produced["records"]], ["A1"])

    def test_an_element_the_bundle_does_not_declare_is_rejected(self):
        node = {"_NODE_TYPE": "WIDGET", "UID": "W1"}
        with self.assertRaises(export.ExportError) as caught:
            export.candidate_from_export(one_document([node]), SAMPLE_BUNDLE)
        self.assertIn("WIDGET", str(caught.exception))
        self.assertIn("Sample", str(caught.exception))

    def test_a_field_declared_by_neither_grammar_is_rejected(self):
        with self.assertRaises(export.ExportError) as caught:
            export.candidate_from_export(
                one_document([item("A1", INVENTED="x")]), SAMPLE_BUNDLE
            )
        self.assertIn("INVENTED", str(caught.exception))

    def test_a_node_with_no_uid_is_rejected(self):
        node = {"_NODE_TYPE": "ITEM", "AUTHORED_BY": "llm\n"}
        with self.assertRaises(export.ExportError) as caught:
            export.candidate_from_export(one_document([node]), SAMPLE_BUNDLE)
        self.assertIn("UID", str(caught.exception))

    def test_a_repeated_uid_is_rejected(self):
        with self.assertRaises(export.ExportError) as caught:
            export.candidate_from_export(
                one_document([item("A1"), item("A1")]), SAMPLE_BUNDLE
            )
        self.assertIn("A1", str(caught.exception))

    def test_a_relation_with_no_role_is_rejected(self):
        node = item("A1", RELATIONS=[{"TYPE": "Parent", "VALUE": "A0"}])
        with self.assertRaises(export.ExportError) as caught:
            export.candidate_from_export(one_document([node]), SAMPLE_BUNDLE)
        self.assertIn("ROLE", str(caught.exception))

    def test_a_relation_with_no_target_is_rejected(self):
        node = item("A1", RELATIONS=[{"TYPE": "Parent", "ROLE": "K"}])
        with self.assertRaises(export.ExportError) as caught:
            export.candidate_from_export(one_document([node]), SAMPLE_BUNDLE)
        self.assertIn("VALUE", str(caught.exception))

    def test_a_reverse_label_is_rejected_by_name(self):
        """A reverse label is never an occurrence (contract.md:498-499).

        StrictDoc lists a relation on the owning node only, so this cannot arise
        from a parse today. Naming the role it mirrors keeps the failure legible
        if that ever changes, rather than reporting an unknown role.
        """
        node = item("A1", RELATIONS=[{"TYPE": "Parent", "ROLE": "K_back", "VALUE": "A0"}])
        with self.assertRaises(export.ExportError) as caught:
            export.candidate_from_export(one_document([node]), SAMPLE_BUNDLE)
        self.assertIn("K_back", str(caught.exception))
        self.assertIn("reverse label", str(caught.exception))

    def test_a_role_the_bundle_does_not_declare_is_rejected(self):
        node = item("A1", RELATIONS=[{"TYPE": "Parent", "ROLE": "M", "VALUE": "A0"}])
        with self.assertRaises(export.ExportError) as caught:
            export.candidate_from_export(one_document([node]), SAMPLE_BUNDLE)
        self.assertIn("M", str(caught.exception))

    def test_created_carries_the_caller_s_uids_and_rejects_a_repeat(self):
        produced = export.candidate_from_export(
            one_document([item("A1")]), SAMPLE_BUNDLE, ["A1", "A9"]
        )
        self.assertEqual(produced["created"], ["A1", "A9"])
        with self.assertRaises(export.ExportError) as caught:
            export.candidate_from_export(
                one_document([item("A1")]), SAMPLE_BUNDLE, ["A1", "A1"]
            )
        self.assertIn("A1", str(caught.exception))


@unittest.skipUnless(shutil.which("strictdoc"), SHELL_MESSAGE)
class CorpusExportTest(unittest.TestCase):
    def test_exporting_the_corpus_reproduces_the_packet_candidate(self):
        """The whole chain, front end included, against the delivered candidate.

        The script defaults to the fixture root as the StrictDoc project root
        and to the packet bundle, so this call passes only an output path.
        """
        produced, _ = self.export()
        self.assertEqual(
            produced,
            self.delivered_candidate(),
            "The exported corpus no longer equals the delivered candidate.json.",
        )

    def test_naming_the_documents_directory_exports_the_same_corpus(self):
        """--project takes a directory inside the project, not only its root.

        StrictDoc reads its input path as the project root, so handing it
        ``documents`` aborts on the ``@repo`` grammar import. The script walks up
        to the nearest strictdoc config instead, and says on standard error which
        root it settled on. ``include_doc_paths`` narrows the export to
        ``documents/**``, so the corpus is the same one either way.
        """
        documents = FIXTURE_ROOT / "documents"
        produced, completed = self.export("--project", str(documents))
        self.assertIn(str(FIXTURE_ROOT), completed.stderr)
        self.assertEqual(
            produced,
            self.delivered_candidate(),
            "Naming documents/ no longer exports the delivered corpus.",
        )

    def test_the_corpus_authors_a_block_form_field_with_a_trailing_newline(self):
        """The real corpus, not a built export, carries the unmatchable value.

        The mapping test above builds its own node. This one exports the
        corpus against a bundle widened to declare AUTHORED_BY, so the value
        comes from the .sdoc files themselves. Every record carries ``llm\n``,
        which is why the delivered bundle leaves the field out rather than
        declaring it and writing rules against it.
        """
        widened = bundle_declaring_authored_by(
            json.loads((PACKET_DIRECTORY / "bundle.json").read_text(encoding="utf-8")),
            "FOO",
        )
        with tempfile.TemporaryDirectory() as directory:
            bundle_path = pathlib.Path(directory) / "bundle.json"
            bundle_path.write_text(json.dumps(widened), encoding="utf-8")
            produced, _ = self.export("--bundle", str(bundle_path))
        authored = {
            record["uid"]: record["fields"].get("AUTHORED_BY")
            for record in produced["records"]
            if record["element"] == "FOO"
        }
        self.assertTrue(authored, "the corpus holds no FOO record")
        self.assertEqual(set(map(tuple, authored.values())), {("llm\n",)})

    def test_a_directory_in_no_strictdoc_project_is_refused(self):
        """The walk up fails loudly rather than exporting some other project."""
        with tempfile.TemporaryDirectory(dir="/tmp") as outside:
            completed = subprocess.run(
                [str(EXPORT_SCRIPT), "--project", outside, "--out", "-"],
                cwd=str(BACKEND_DIRECTORY),
                capture_output=True,
                text=True,
                timeout=600,
                check=False,
            )
        self.assertEqual(completed.returncode, 2, completed.stderr)
        self.assertIn("no strictdoc_config.py or strictdoc.toml", completed.stderr)

    def delivered_candidate(self):
        return json.loads(
            (PACKET_DIRECTORY / "candidate.json").read_text(encoding="utf-8")
        )

    def export(self, *extra):
        """Run the script into a temporary file and return what it wrote."""
        with tempfile.TemporaryDirectory() as output_directory:
            output_path = pathlib.Path(output_directory) / "candidate.json"
            completed = subprocess.run(
                [str(EXPORT_SCRIPT), "--out", str(output_path), *extra],
                cwd=str(BACKEND_DIRECTORY),
                capture_output=True,
                text=True,
                timeout=600,
                check=False,
            )
            self.assertEqual(
                completed.returncode,
                0,
                "The exporter failed.\nstdout: %s\nstderr: %s"
                % (completed.stdout, completed.stderr),
            )
            self.assertTrue(
                output_path.is_file(),
                "The exporter wrote no file at --out.\nstderr: %s" % completed.stderr,
            )
            return json.loads(output_path.read_text(encoding="utf-8")), completed


if __name__ == "__main__":
    unittest.main()
