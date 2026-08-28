# cspell:ignore uids sdoc autogen parallelizer textx arpeggio
"""sdoc_model -- the one write path for .sdoc files, over strictdoc's own
node model (MECH-SDOC-EDIT-VIA-MODEL,
docs/plans/strictdoc-tooling/mech-sdoc-edit-via-model.sdoc).

Replaces dev/scripts/sdoc_edit.py, which carried a hand-copied FIELD_ORDER
table and located field blocks with regexes. Nothing here knows the
grammar's field order or its block syntax: strictdoc's writer owns both, so
a grammar change reaches this module for free and the "run strictdoc format
afterward" step disappears -- SDWriter emits the canonical form directly.
Measured on this corpus: SDWriter().write(doc) is byte-identical to the
formatted file on disk.

Two consumers, and the split is deliberate. sdoc_cli.py is the verb and
flag surface; fp-accept.py writes exactly one field. Both go through Graph.

THREE OBLIGATIONS SIT HERE BECAUSE STRICTDOC DOES NOT CARRY THEM:

* Value validation. SDocNode.set_field_value performs none -- an invalid
  SingleChoice and the deletion of a required field both serialize cleanly
  and reach disk, caught only by a later parse. validate_node is the
  catchable gate.
* Delimiter rejection. A value carrying a line that begins at column zero
  with `<<<` serializes to a file that cannot be re-parsed, and
  validate_node does not see it. check_value_delimiters rejects it here.
* Path discovery. The model gives each node its own source file, so
  fp-accept's glob-and-grep scan for a "UID: " line is gone.

WHAT THIS MODULE DOES NOT DO is enforce instance semantics -- who may sign,
whether DEPTH may regress, when deleting is legitimate. Those are milestone
five's (SLICE-INSTANCE-SEMANTICS-MIGRATION). The only instance rule here is
the guarded field set, which is MECH-RUNTIME-WRITE-GUARD's absence-of-a-code-
path and belongs to the runtime by that node's ruling.
"""

from __future__ import annotations

import contextlib
import io
import os
import sys
from pathlib import Path
from typing import Iterator

from strictdoc.backend.sdoc.document_reference import DocumentReference
from strictdoc.backend.sdoc.models.document import SDocDocument
from strictdoc.backend.sdoc.models.grammar_element import GrammarElement
from strictdoc.backend.sdoc.models.node import SDocNode, SDocNodeField
from strictdoc.backend.sdoc.models.reference import (
    FileEntry,
    FileReference,
    ParentReqReference,
)
from strictdoc.backend.sdoc.validations.sdoc_validator import SDocValidator
from strictdoc.backend.sdoc.writer import SDWriter
from strictdoc.core.project_config import ProjectConfigLoader
from strictdoc.core.traceability_index_builder import TraceabilityIndexBuilder
from strictdoc.helpers.parallelizer import NullParallelizer

# MECH-RUNTIME-WRITE-GUARD: two fields are the operator's, and what enforces
# that is the absence of a code path rather than a check in front of one.
# sdoc_cli derives its field flags from the grammar MINUS this set, so no
# flag for either exists to pass. There is deliberately no override.
#
# AUTHORED_BY is REQUIRED on all five element types, so `new` cannot omit it
# and writes `llm` unconditionally; the operator records their own authorship
# by an edit outside the tool. PARENT_FP is optional everywhere it appears
# and absent from DECISION, so the CLI never emits it at all -- fp-accept.py
# stays its only writer, and reaches it through set_field below, which is why
# this set is advisory to the CLI rather than enforced in Graph.
GUARDED_FIELDS = ("AUTHORED_BY", "PARENT_FP")

GUARDED_OWNERS = {
    "AUTHORED_BY": (
        "the operator, by an edit outside this tool -- it records who wrote "
        "the statement (MECH-RUNTIME-WRITE-GUARD)"
    ),
    "PARENT_FP": (
        "dev/scripts/fp-accept.py, and signing is the operator's key "
        "(DEC-FINGERPRINT-IN-NODE)"
    ),
}

# The whole of a one-node-per-file document that is not the node
# (MECH-ONE-NODE-PER-FILE). The @repo alias is what lets a document at any
# depth share one grammar -- see strictdoc_config.py.
DOCUMENT_SKELETON = "[DOCUMENT]\nTITLE: {title}\n\n[GRAMMAR]\nIMPORT_FROM_FILE: @repo\n"


class SdocError(Exception):
    """Anything the caller should print and exit non-zero on."""


def validate_guarded(graph) -> None:
    """MECH-RUNTIME-WRITE-GUARD: "The list is validated against the loaded
    grammar, so a guarded name the grammar no longer declares is an error
    rather than a silently dead entry."

    Without this the guard degrades into dead code the day a field is
    renamed, and it degrades SILENTLY -- the flag it was suppressing simply
    starts existing again. That is the one failure mode a guard built out of
    an absence cannot survive on its own.
    """
    declared = {
        field.title
        for tag in graph.tags()
        for field in graph.element(tag).fields
    }
    orphans = [name for name in GUARDED_FIELDS if name not in declared]
    if orphans:
        raise SdocError(
            f"guarded field(s) {', '.join(orphans)} are no longer declared by "
            f"the grammar, so guarding them protects nothing. Fix "
            f"GUARDED_FIELDS in dev/scripts/sdoc_model.py to match, and check "
            f"whether MECH-RUNTIME-WRITE-GUARD still says what it means."
        )


def check_value_delimiters(field: str, value: str) -> None:
    """Reject a value that would serialize into an unparsable file.

    A multiline field is written between `>>>` and `<<<`, and only the
    CLOSING marker is matched at column zero, so a value carrying such a line
    terminates its own block early and strands the rest as syntax.
    validate_node does not see this -- the node is well-formed in memory and
    only the file is broken.

    `>>>` is deliberately NOT rejected. An earlier draft refused it too, on
    the symmetry argument, and that is a false positive: measured, a bare
    `>>>` line inside a block round-trips intact, because the opening marker
    is only meaningful on the field's own line. Refusing it would reject
    legitimate prose -- this file's own docstrings among it.
    """
    for lineno, line in enumerate(value.splitlines(), start=1):
        if line.startswith("<<<"):
            raise SdocError(
                f"{field}: line {lineno} begins at column zero with "
                f"{line[:3]!r}, which would close the block and make the "
                f"written file unparsable. Indent the line by one space."
            )


def normalize_file_value(value: str) -> str:
    """MECH-FILE-RELATION-EXISTENCE's well-formedness rule.

    A File relation VALUE is well-formed in exactly one shape: a normalized
    POSIX path relative to the repository root, not absolute, with no
    leading `./` and no `..` segment. Any other shape is a finding in its
    own right rather than a path to normalize and then resolve -- that rule
    is upstream's, whose own file-traceability validation accepts precisely
    this shape, so holding to it keeps the corpus able to turn that feature
    on later.

    Returns the value unchanged when well-formed; raises otherwise.
    """
    if value != value.strip():
        raise SdocError(f"File relation {value!r} has leading or trailing whitespace")
    if not value:
        raise SdocError("File relation VALUE is empty")
    if os.path.isabs(value) or value.startswith("/"):
        raise SdocError(f"File relation {value!r} is absolute; use a repository-relative path")
    if "\\" in value:
        raise SdocError(f"File relation {value!r} is not a POSIX path")
    parts = value.split("/")
    if parts[0] == "." or "." in parts:
        raise SdocError(f"File relation {value!r} has a './' segment; write the bare path")
    if ".." in parts:
        raise SdocError(f"File relation {value!r} has a '..' segment")
    if "" in parts:
        raise SdocError(f"File relation {value!r} has an empty path segment")
    return value


class Graph:
    """One loaded project tree, mutated in memory and written on save().

    The graph load is the expensive step -- about 1.7 s cold and 0.25 s
    against a warm cache on this corpus -- so batching is the point:
    fp-accept signs several UIDs per run and the CLI applies one change,
    both through one load.
    """

    def __init__(self, root: Path, project_config, index) -> None:
        self.root = root
        self.config = project_config
        self.index = index
        self._dirty: dict[str, SDocDocument] = {}
        self._removed: list[Path] = []

    # ---- reading -------------------------------------------------------

    @property
    def documents(self) -> list[SDocDocument]:
        return list(self.index.document_tree.document_list)

    @property
    def grammar(self):
        """The one grammar every document shares, via the @repo alias.

        Read off the first document rather than from the .sgra file: the
        alias is resolved during the traceability index build, not by the
        reader, so the parsed grammar is the only one that reflects what a
        document actually validates against.
        """
        for document in self.documents:
            if document.grammar is not None:
                return document.grammar
        raise SdocError("no document in the tree carries a grammar")

    def element(self, tag: str) -> GrammarElement:
        elements = self.grammar.elements_by_type
        if tag not in elements:
            known = ", ".join(t for t in elements if t != "TEXT")
            raise SdocError(f"the grammar declares no {tag!r} element. Known: {known}")
        return elements[tag]

    def tags(self) -> list[str]:
        """Every author-facing element tag. TEXT is strictdoc's own
        free-text element, back-filled by the index builder rather than
        declared by our grammar, and is not a node type anyone writes."""
        return [t for t in self.grammar.elements_by_type if t != "TEXT"]

    def node(self, uid: str) -> SDocNode:
        found = self.index.get_node_by_uid_weak(uid)
        if found is None:
            raise SdocError(f"no node with UID {uid!r} in the graph")
        return found

    def has_node(self, uid: str) -> bool:
        return self.index.get_node_by_uid_weak(uid) is not None

    def iter_nodes(self) -> Iterator[SDocNode]:
        for document in self.documents:
            for node in document.section_contents:
                if isinstance(node, SDocNode) and node.node_type != "TEXT":
                    yield node

    def path_of(self, node: SDocNode) -> Path:
        document = node.get_document()
        if document is None or document.meta is None:
            raise SdocError(f"node {node.reserved_uid!r} has no source file")
        return Path(document.meta.input_doc_full_path)

    # ---- mutation ------------------------------------------------------

    def _touch(self, document: SDocDocument) -> None:
        self._dirty[document.meta.input_doc_full_path] = document

    def set_field(self, uid: str, field: str, value: str | None) -> None:
        """Set (or, with value=None, delete) one field on one node.

        Validates before returning and raises rather than leaving a bad
        node in the graph -- set_field_value itself accepts anything.
        """
        node = self.node(uid)
        element = self.element(node.node_type)
        if field not in element.field_titles:
            raise SdocError(
                f"{node.node_type} declares no field {field!r}. "
                f"Declared: {', '.join(element.field_titles)}"
            )
        if value is not None:
            check_value_delimiters(field, value)
        node.set_field_value(field_name=field, form_field_index=0, value=value)
        self.validate(node)
        self._touch(node.get_document())

    def add_relation(self, uid: str, role: str, target: str) -> None:
        node = self.node(uid)
        element = self.element(node.node_type)
        if self._find_relation(node, role, target) is not None:
            raise SdocError(f"{uid} already has a {role or 'File'} relation to {target!r}")
        node.relations.append(self._build_reference(node, element, role, target))
        self.validate(node)
        self._touch(node.get_document())

    def remove_relation(self, uid: str, role: str, target: str) -> None:
        node = self.node(uid)
        existing = self._find_relation(node, role, target)
        if existing is None:
            raise SdocError(f"{uid} has no {role or 'File'} relation to {target!r}")
        node.relations.remove(existing)
        self.validate(node)
        self._touch(node.get_document())

    def _build_reference(self, node: SDocNode, element: GrammarElement, role: str, target: str):
        """One relation, checked against the grammar and the tree.

        The two callers -- add_relation on an existing node and add_node on a
        fresh one -- were the same fifteen lines twice, which is how the File
        branch and the Parent branch drift apart.
        """
        if self._relation_type_for_role(element, role) != "File":
            if not self.has_node(target):
                raise SdocError(f"relation target {target!r} is not a node in the graph")
            return ParentReqReference(parent=node, ref_uid=target, role=role)

        normalize_file_value(target)
        if not (self.root / target).is_file():
            raise SdocError(
                f"File relation {target!r} does not name an existing regular "
                f"file under {self.root}"
            )
        entry = FileEntry(
            parent=None,
            g_file_format=None,
            g_file_path=target,
            # Emits `VALUE:` rather than `PATH:`. Both parse; the writer picks
            # the spelling from whether this deprecated field is set, and all
            # three File relations in the corpus carry VALUE. Uniformity wins
            # here because MECH-FILE-RELATION-EXISTENCE's corpus-wide gate
            # reads a VALUE, and a corpus split across two spellings would
            # need it to read both. Migrating the corpus to PATH is a separate
            # change, not a side effect of the first tool that writes one.
            g_deprecated_file_path=target,
            g_line_range=None,
        )
        reference = FileReference(parent=node, g_file_entry=entry)
        entry.parent = reference
        return reference

    @staticmethod
    def _find_relation(node: SDocNode, role: str, target: str):
        for relation in node.relations:
            if isinstance(relation, FileReference):
                if not role and file_path_of(relation) == target:
                    return relation
                continue
            if relation.ref_uid == target and (relation.role or "") == role:
                return relation
        return None

    @staticmethod
    def _relation_type_for_role(element: GrammarElement, role: str) -> str:
        """Map a --role to the relation TYPE the grammar declares for it.

        The empty role is File: a File relation carries a VALUE alone in
        this corpus, and the grammar declares it with no ROLE at all.
        """
        for relation in element.relations:
            if relation.relation_type == "File" and not role:
                return "File"
            if getattr(relation, "relation_role", None) == role and role:
                return relation.relation_type
        roles = roles_of(element)
        raise SdocError(
            f"{element.tag} may not make a {role or 'File'!r} relation. "
            f"Declared roles: {', '.join(roles) or '(none)'}"
        )

    def create_document(self, path: Path, title: str) -> None:
        """Write the two invariant header blocks for a new one-node file.

        The node itself is added through the model on the next load. This
        five-line skeleton is the only sdoc text this tool templates, and it
        is deliberate: the @repo alias resolves during the index build, so a
        document constructed purely in memory would have to be handed a
        grammar and a meta by hand -- exactly the wiring the model exists to
        avoid getting wrong.
        """
        if path.exists():
            raise SdocError(f"{path} already exists")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(DOCUMENT_SKELETON.format(title=title), encoding="utf8")

    def add_node(
        self,
        document: SDocDocument,
        tag: str,
        values: dict[str, str],
        relations: list[tuple[str, str]],
    ) -> SDocNode:
        element = self.element(tag)
        fields: list[SDocNodeField] = []
        for grammar_field in element.fields:
            title = grammar_field.title
            if title == "MID":
                continue
            if title not in values:
                if grammar_field.required:
                    raise SdocError(f"{tag} requires a {title} value")
                continue
            value = values[title]
            # SDocNodeField.create_from_string ASSERTS len(value) > 0, which
            # would surface as a bare AssertionError traceback. The `set` path
            # gets this for free from validate_node; `new` does not, because
            # the field never reaches the node.
            if not value:
                raise SdocError(
                    f"{title} is empty. A field with no value is not a field -- "
                    f"omit it if it is optional, or use `set --unset` to remove one."
                )
            check_value_delimiters(title, value)
            fields.append(
                SDocNodeField.create_from_string(
                    parent=None,
                    field_name=title,
                    field_value=value,
                    # Chosen from the GRAMMAR rather than from the value's
                    # shape, so a one-line STATEMENT is still a block and the
                    # corpus stays uniform.
                    multiline=element.is_field_multiline(title),
                )
            )
        node = SDocNode(parent=document, node_type=tag, fields=fields, relations=[])
        node.ng_document_reference = DocumentReference()
        node.ng_document_reference.set_document(document)
        for field in fields:
            field.parent = node
        document.section_contents.append(node)
        for role, target in relations:
            node.relations.append(self._build_reference(node, element, role, target))
        self.validate(node)
        self._touch(document)
        return node

    def remove_node(self, uid: str) -> Path:
        """Drop a node and, with it, its file -- one node per file means the
        document has nothing left to hold."""
        node = self.node(uid)
        document = node.get_document()
        path = self.path_of(node)
        # Checked BEFORE the mutation, not after. An earlier version removed
        # the node and then raised, leaving the in-memory graph inconsistent
        # with disk -- inert for a one-shot CLI process, but fp-accept.py
        # already reuses one Graph across several operations.
        siblings = [
            other
            for other in document.section_contents
            if isinstance(other, SDocNode) and other.node_type != "TEXT" and other is not node
        ]
        if siblings:
            raise SdocError(
                f"{path} holds {len(siblings) + 1} nodes; this tool writes and "
                f"removes one-node documents only (MECH-ONE-NODE-PER-FILE)"
            )
        document.section_contents.remove(node)
        self._removed.append(path)
        self._dirty.pop(document.meta.input_doc_full_path, None)
        return path

    # ---- validation and writing ---------------------------------------

    def validate(self, node: SDocNode) -> None:
        document = node.get_document()
        try:
            SDocValidator.validate_node(
                node,
                document_grammar=document.grammar,
                path_to_sdoc_file=document.meta.input_doc_full_path,
            )
        except Exception as exc:  # strictdoc raises StrictDocException subclasses
            raise SdocError(str(exc)) from exc

    def render(self, document: SDocDocument) -> str:
        return SDWriter(self.config).write(document)

    def pending(self) -> dict[Path, str | None]:
        """Path -> new content, or None for a deletion. Ordered for a
        stable --dry-run diff."""
        out: dict[Path, str | None] = {}
        for path in sorted(self._removed):
            out[path] = None
        for _, document in sorted(self._dirty.items()):
            out[Path(document.meta.input_doc_full_path)] = self.render(document)
        return out

    def save(self) -> list[Path]:
        """Write only the documents whose nodes were touched.

        Atomic per file: a temporary sibling is renamed over the target, so
        a concurrent reader -- this repository is routinely co-occupied --
        sees old bytes or new bytes, never a partial document.
        """
        written: list[Path] = []
        for path, content in self.pending().items():
            if content is None:
                path.unlink()
                written.append(path)
                continue
            temporary = path.with_name(f".{path.name}.sdoc-tmp")
            temporary.write_text(content, encoding="utf8")
            temporary.replace(path)
            written.append(path)
        self._dirty.clear()
        self._removed.clear()
        return written


def field_value(node: SDocNode, name: str) -> str | None:
    """A field's text, or None when the node does not carry it.

    get_field_by_name raises on an absent field, and absence is ordinary
    here: DEPTH is on four of the five types and STATUS on two, so every
    caller iterating over both needs this guard.
    """
    if name not in node.ordered_fields_lookup:
        return None
    return node.get_field_by_name(name).get_text_value()


def file_path_of(relation: FileReference) -> str:
    """The repository-relative path a File relation names."""
    return relation.get_posix_path()


def roles_of(element: GrammarElement) -> list[str]:
    """Every relation role the element declares, File's empty role
    included as the literal `File`."""
    roles = []
    for relation in element.relations:
        if relation.relation_type == "File":
            roles.append("File")
        else:
            role = getattr(relation, "relation_role", None)
            if role:
                roles.append(role)
    return roles


def open_graph(root: Path, *, output_dir: Path | None = None) -> Graph:
    """Load the whole project tree.

    Chdir to the project root before ProjectConfig is constructed: the
    parse cache path is keyed on the cwd at that moment
    (MECH-SDOC-CACHE-DIR-FOR-WORKTREES), so a command run from a
    subdirectory would otherwise get its own cold cache. The output
    directory is fixed for the same reason -- each cached parse is keyed on
    output_dir concatenated with the input path, so a fresh one is a cold
    cache and leaves a second full set of entries behind.
    """
    root = root.resolve()
    output_dir = output_dir or (root / "output")
    previous = Path.cwd()
    os.chdir(root)
    # strictdoc narrates every step of the load on stdout, which would put a
    # progress bar in the middle of --dry-run's diff and in front of every
    # machine-readable listing. Held in a buffer and re-emitted only when the
    # load fails, where it carries the parse error's context.
    chatter = io.StringIO()
    try:
        with contextlib.redirect_stdout(chatter):
            project_config = ProjectConfigLoader.load(
                input_path=str(root), output_dir=str(output_dir)
            )
            index = TraceabilityIndexBuilder.create(
                project_config=project_config,
                parallelizer=NullParallelizer(),
                skip_source_files=True,
            )
    except BaseException:
        print(chatter.getvalue(), end="", file=sys.stderr)
        raise
    finally:
        os.chdir(previous)
    return Graph(root, project_config, index)
