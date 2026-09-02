# cspell:ignore uids sdoc autogen parallelizer textx arpeggio unrelate
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
import inspect
import io
import posixpath
import tempfile
import os
import sys
from pathlib import Path
from typing import Iterator, NamedTuple

from strictdoc.backend.sdoc.document_reference import DocumentReference
from strictdoc.backend.sdoc.models.document import SDocDocument
from strictdoc.backend.sdoc.models.document_grammar import DocumentGrammar
from strictdoc.backend.sdoc.models.grammar_element import GrammarElement
from strictdoc.backend.sdoc.models.node import SDocNode, SDocNodeField
from strictdoc.backend.sdoc.models.reference import (
    ChildReqReference,
    FileEntry,
    FileReference,
    ParentReqReference,
)
from strictdoc.backend.sdoc.reader import SDReader
from strictdoc.backend.sdoc.validations.sdoc_validator import SDocValidator
from strictdoc.backend.sdoc.writer import SDWriter
from strictdoc.backend.sdoc_source_code.models.language_item_marker import (
    RangeMarkerType,
)
from strictdoc.core.document_meta import DocumentMeta
from strictdoc.core.project_config import ProjectConfigLoader
from strictdoc.core.traceability_index_builder import TraceabilityIndexBuilder
from strictdoc.helpers.parallelizer import NullParallelizer
from strictdoc.helpers.path_filter import PathFilter
from strictdoc.helpers.paths import SDocRelativePath
from strictdoc.helpers.textx import drop_textx_meta

# MECH-RUNTIME-WRITE-GUARD: two fields are the operator's, and what enforces
# that is the absence of a code path rather than a check in front of one.
# sdoc_cli derives its field flags from the grammar MINUS this set, so no
# flag for either exists to pass. There is deliberately no override.
#
# AUTHORED_BY is REQUIRED on every element type, so `new` cannot omit it
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


# --------------------------------------------------------------------------
# Element-grained File relations
# --------------------------------------------------------------------------
#
# A File relation may name a PART of the file rather than the whole of it:
# `ELEMENT: function` + `ID: <qualified name>`, optionally a LINE_RANGE.
# Neither the ELEMENT vocabulary nor the slot names live in the .sgra
# grammar -- the File relation is declared there by TYPE alone -- so both
# are derived from strictdoc rather than written down a second time here.
# A strictdoc bump that renames either fails at import with the file and
# the symbol named, instead of silently writing a relation nothing reads.

# ELEMENT is a CLOSED vocabulary, and it is closed twice over: RangeMarkerType
# below, and the marker lexer's own regex. `file` is the whole-file scope a
# source marker carries, not something a File relation may name, so a
# relation's ELEMENT is exactly the remainder.
FILE_ELEMENTS = tuple(
    marker.value for marker in RangeMarkerType if marker is not RangeMarkerType.FILE
)

# The FileEntry keyword each slot is carried by. The ID slot is spelled `id`
# and the line range `g_line_range` (a STRING; FileEntry parses it into the
# `line_range` tuple), which is exactly the kind of detail worth deriving
# once and asserting rather than repeating at three call sites.
FILE_ENTRY_SLOTS = {"element": "element", "id": "id", "line_range": "g_line_range"}


def _check_file_entry_slots() -> None:
    accepted = inspect.signature(FileEntry.__init__).parameters
    missing = sorted(slot for slot in FILE_ENTRY_SLOTS.values() if slot not in accepted)
    if missing:
        raise SdocError(
            f"strictdoc's FileEntry no longer accepts {', '.join(missing)} -- "
            f"dev/scripts/sdoc_model.py FILE_ENTRY_SLOTS needs re-deriving from "
            f"strictdoc/backend/sdoc/models/reference.py"
        )


_check_file_entry_slots()


class RelationSpec(NamedTuple):
    """One relation as a caller states it, before the grammar is consulted.

    `role` is already the GRAMMAR's role -- the empty string for File (see
    relation_role below). The last three are File-only and None everywhere
    else. Plain `(role, target)` tuples are still accepted by add_node, so
    an old caller keeps working.
    """

    role: str
    target: str
    element: str | None = None
    id: str | None = None
    line_range: str | None = None


def relation_role(role: str) -> str:
    """The role a caller typed, as the grammar spells it.

    A File relation declares NO role at all, so the grammar's role for it is
    the empty string, while every human-facing surface -- the CLI's --role
    choices, the daemon's `role` parameter, roles_of() above -- names it
    `File`. This is the one place that mapping lives; it used to be four,
    and the daemon's relate verb was the copy that did not get it
    (WORK-SCRIBE-RELATE-FILE-ROLE).
    """
    return "" if role == "File" else role


def normalize_line_range(raw: str | None) -> str | None:
    """`12-20`, `12,20` or `12, 20` -> the one spelling FileEntry parses.

    FileEntry splits on the literal `", "` and asserts exactly two
    components, so a tuple or a comma with no space raises an
    AssertionError from inside the parser rather than anything a caller can
    catch. Normalizing here keeps that AssertionError unreachable.
    """
    if raw is None or raw == "":
        return None
    text = raw.replace("-", ",").replace(" ", "")
    parts = [part for part in text.split(",") if part != ""]
    if len(parts) != 2 or not all(part.isdigit() for part in parts):
        raise SdocError(f"line range {raw!r} is not two line numbers, as in 245-247")
    begin, end = int(parts[0]), int(parts[1])
    if begin < 1 or end < begin:
        raise SdocError(f"line range {raw!r} does not run forward from line 1 or later")
    return f"{begin}, {end}"


def file_entry_kwargs(element: str | None, id_: str | None, line_range: str | None) -> dict:
    """Validate the three element-grained slots and shape them for FileEntry.

    Two refusals are strictdoc's rather than ours, and both would otherwise
    be SILENT:

    * ELEMENT without ID resolves to nothing. The forward resolver matches
      an ID against the parsed items of the file; an ELEMENT alone names no
      item, and strictdoc's own writer drops a lone ELEMENT on the next
      format, so the relation would degrade to a whole-file one with no
      diagnostic at all.
    * ELEMENT + ID + LINE_RANGE cannot round-trip. SDWriter emits these
      slots from an if/elif CHAIN (writer.py:541-575): with ELEMENT and ID
      both set it takes the first arm and LINE_RANGE is never written. A
      relation carrying all three would be silently narrowed by the next
      `strictdoc format`, which is exactly the kind of drift the
      write-then-reload guard exists to make impossible.
    """
    line_range = normalize_line_range(line_range)
    if element is not None and element not in FILE_ELEMENTS:
        raise SdocError(
            f"ELEMENT {element!r} is not one of {', '.join(FILE_ELEMENTS)}. "
            f"The KIND of the item (module, option, binding) is not an ELEMENT "
            f"value -- it reaches a reader through the item's description."
        )
    if element is not None and not id_:
        raise SdocError("--element names the kind of item; it needs an --id to name which one")
    if element is not None and line_range is not None:
        raise SdocError(
            "a File relation carries ELEMENT+ID or LINE_RANGE, not both: "
            "strictdoc's writer emits the first and would drop the range"
        )
    return {
        FILE_ENTRY_SLOTS["element"]: element,
        FILE_ENTRY_SLOTS["id"]: id_,
        FILE_ENTRY_SLOTS["line_range"]: line_range,
    }


def _describe(spec: RelationSpec) -> str:
    """A relation as an error message should name it: the target, plus the
    element it narrows to when it narrows to one."""
    text = repr(spec.target)
    if spec.element or spec.id:
        text += f" ({spec.element or '?'} {spec.id or '?'})"
    elif spec.line_range:
        text += f" (lines {spec.line_range})"
    return text


def file_entry_of(relation: FileReference) -> dict:
    """The element-grained slots a File relation carries, absent ones None.

    One reader for `show`, the export patch and any test: FileEntry
    back-fills element/id from the deprecated FUNCTION:/CLASS: spellings in
    its own constructor, so reading the attributes rather than the source
    text gets a corpus written the old way right for free.
    """
    entry = getattr(relation, "g_file_entry", None)
    if entry is None:
        return {"element": None, "id": None, "line_range": None}
    return {
        "element": getattr(entry, "element", None),
        "id": getattr(entry, "id", None),
        "line_range": getattr(entry, "g_line_range", None),
    }


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

    def add_relation(
        self,
        uid: str,
        role: str,
        target: str,
        *,
        file_element: str | None = None,
        file_id: str | None = None,
        line_range: str | None = None,
    ) -> None:
        node = self.node(uid)
        element = self.element(node.node_type)
        spec = RelationSpec(role, target, file_element, file_id, line_range)
        # BEFORE the duplicate check, not inside _build_reference alone: a
        # node-to-node relation carrying File slots would otherwise be
        # refused by whichever check fired first, and "already has that
        # relation" is a misleading answer to "ELEMENT is not for a Parent".
        self._check_file_slots(self._relation_type_for_role(element, role), spec)
        if self._find_relation(node, spec) is not None:
            raise SdocError(
                f"{uid} already has a {role or 'File'} relation to {_describe(spec)}"
            )
        node.relations.append(self._build_reference(node, element, spec))
        self.validate(node)
        self._touch(node.get_document())

    def remove_relation(
        self,
        uid: str,
        role: str,
        target: str,
        *,
        file_element: str | None = None,
        file_id: str | None = None,
        line_range: str | None = None,
    ) -> None:
        node = self.node(uid)
        spec = RelationSpec(role, target, file_element, file_id, line_range)
        self._check_file_slots(
            self._relation_type_for_role(self.element(node.node_type), role), spec
        )
        existing = self._find_relation(node, spec)
        if existing is None:
            existing = self._sole_relation_to(node, spec)
        node.relations.remove(existing)
        self.validate(node)
        self._touch(node.get_document())

    @staticmethod
    def _sole_relation_to(node: SDocNode, spec: RelationSpec):
        """The one File relation naming this path, when the caller named no
        element.

        Element-grained linking makes several relations to ONE path
        ordinary, so `unrelate --target <path>` is ambiguous exactly when
        more than one exists. Refusing beats removing whichever came first.
        """
        candidates = [
            relation
            for relation in node.relations
            if isinstance(relation, FileReference) and file_path_of(relation) == spec.target
        ]
        named = spec.element is not None or spec.id is not None or spec.line_range is not None
        if not spec.role and not named and len(candidates) == 1:
            return candidates[0]
        uid = node.reserved_uid
        if not spec.role and not named and len(candidates) > 1:
            raise SdocError(
                f"{uid} has {len(candidates)} File relations to {spec.target!r}; "
                f"name which one with --element/--id: "
                f"{', '.join(sorted(str(file_entry_of(c)['id']) for c in candidates))}"
            )
        raise SdocError(f"{uid} has no {spec.role or 'File'} relation to {_describe(spec)}")

    def _build_reference(self, node: SDocNode, element: GrammarElement, spec: RelationSpec):
        """One relation, checked against the grammar and the tree.

        The two callers -- add_relation on an existing node and add_node on a
        fresh one -- were the same fifteen lines twice, which is how the File
        branch and the Parent branch drift apart.
        """
        role, target = spec.role, spec.target
        relation_type = self._relation_type_for_role(element, role)
        self._check_file_slots(relation_type, spec)
        if relation_type != "File":
            if not self.has_node(target):
                raise SdocError(f"relation target {target!r} is not a node in the graph")
            # A Child role points DOWN at something this node owns or produced
            # (Contains, Produces): no dependency, no fingerprint, and the
            # RELATIONS order on this node is the order of its parts.
            if relation_type == "Child":
                return ChildReqReference(parent=node, ref_uid=target, role=role)
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
            **file_entry_kwargs(spec.element, spec.id, spec.line_range),
        )
        reference = FileReference(parent=node, g_file_entry=entry)
        entry.parent = reference
        return reference

    @staticmethod
    def _check_file_slots(relation_type: str, spec: RelationSpec) -> None:
        """ELEMENT, ID and LINE_RANGE name part of a FILE. A node-to-node
        relation has no parts to name."""
        if relation_type != "File" and (spec.element or spec.id or spec.line_range):
            raise SdocError(
                f"ELEMENT, ID and LINE_RANGE belong to a File relation; the "
                f"{spec.role!r} role makes a {relation_type} relation to a node"
            )

    @staticmethod
    def _find_relation(node: SDocNode, spec: RelationSpec):
        """The relation this spec names EXACTLY, or None.

        A File relation is keyed on the path TOGETHER WITH its element and
        id. Keying on the path alone -- which is what this did while a File
        relation could only name a whole file -- refuses a second relation
        to the same file as a duplicate, and a second relation to the same
        file naming a different item is the whole point of element-grained
        linking.
        """
        for relation in node.relations:
            if isinstance(relation, FileReference):
                if spec.role or file_path_of(relation) != spec.target:
                    continue
                entry = file_entry_of(relation)
                if (
                    entry["element"] == spec.element
                    and entry["id"] == spec.id
                    and entry["line_range"] == normalize_line_range(spec.line_range)
                ):
                    return relation
                continue
            if relation.ref_uid == spec.target and (relation.role or "") == spec.role:
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

    def new_document(self, path: Path, title: str) -> SDocDocument:
        """Build a one-node document IN MEMORY, wired as a reload would wire it.

        This is what lets `new` batch like every other write. The skeleton
        used to reach DISK first and the whole corpus was then re-read, because
        the `@repo` alias is resolved by the index builder and not by the
        reader. That reload re-parsed 382 files to obtain a reference to an
        object already in memory: the corpus holds 382 DocumentGrammar objects
        around exactly ONE shared element list.

        Three things have to be true of the result, and each is done the way
        the loader does it rather than approximated:

        * the grammar is resolved through the SAME lookup the index builder
          uses -- the project's alias table, then the document tree's map of
          parsed grammar files -- so the elements ARE that one shared list;
        * the meta is derived from the path. This is the one place this module
          mirrors the loader instead of calling it, and the mirror is held
          honest by a contract rather than by care: every meta field of a
          document built here is compared against a genuine rebuild
          (MECH-SCRIBE-NEW-BUILDS-THE-DOCUMENT, EV-SCRIBE-NEW-IN-ONE-LOAD);
        * the document is registered in all three containers a lookup goes
          through. get_node_by_uid_weak WALKS document_list rather than reading
          the graph database, so a node created here is visible to the rest of
          the batch with no index surgery at all -- which is why creating one
          node and relating the next to it still works without a reload.

        Nothing reaches the disk here. The document joins `pending()` through
        add_node like any other edit, and `save()` creates its directory.
        """
        if path.exists():
            raise SdocError(f"{path} already exists")
        tree = self.index.document_tree
        if str(path) in tree.map_docs_by_paths:
            raise SdocError(f"{path} is already a document in this graph")

        self._refuse_unreadable_destination(self._relative(path))

        document = SDReader.read(DOCUMENT_SKELETON.format(title=title), str(path))
        # The loader strips textX's parse metadata off every document it reads;
        # it is unpicklable and unused, and a document that kept it would be
        # the one object in the tree that could not go through the parse cache.
        drop_textx_meta(document)
        document.assign_meta(self._document_meta(path))
        self._resolve_grammar(document)

        tree.document_list.append(document)
        tree.map_docs_by_paths[str(path)] = document
        tree.map_docs_by_rel_paths[
            os.path.join(
                document.meta.output_document_dir_rel_path.relative_path,
                f"{document.meta.document_filename_base}.html",
            )
        ] = document
        return document

    def _relative(self, path: Path) -> Path:
        try:
            return path.relative_to(self.root)
        except ValueError as exc:
            raise SdocError(f"{path} is outside the project root {self.root}") from exc

    def _refuse_unreadable_destination(self, relative: Path) -> None:
        """Refuse a destination the loader would not read back.

        A document written where DocumentFinder does not look reaches the disk
        and is then simply absent after the next reload: the create reports
        success and the node is gone. The shape this replaces caught that by
        ACCIDENT -- it looked the new document up in a reloaded tree and did
        not find it -- so building in memory has to state the rule instead of
        inheriting it.

        Both rules are FileFinder's. Directories named `output` in either case
        are pruned unconditionally, along with the project's own output
        directory; the include and exclude masks decide the rest, and they go
        through strictdoc's own PathFilter rather than a second reading of its
        glob dialect.
        """
        pruned = {"output", "Output", os.path.basename(str(self.config.output_dir or ""))}
        for part in relative.parts[:-1]:
            if part in pruned:
                raise SdocError(
                    f"{relative.as_posix()} is under {part!r}, a directory "
                    f"strictdoc never reads -- the file would be written and "
                    f"then vanish at the next load"
                )
        posix = relative.as_posix()
        if PathFilter(self.config.exclude_doc_paths, positive_or_negative=False).match(posix):
            raise SdocError(
                f"{posix} is matched by the project's exclude_doc_paths, so "
                f"the document would be written and never read back"
            )
        if not PathFilter(self.config.include_doc_paths, positive_or_negative=True).match(posix):
            raise SdocError(
                f"{posix} is outside the project's include_doc_paths, so the "
                f"document would be written and never read back"
            )

    def _document_meta(self, path: Path) -> DocumentMeta:
        """The meta DocumentFinder would have built for this path.

        Mirrored from core/file_system/document_finder.py's _build_document_tree
        and the File/Folder levels FileFinder assigns. Every value it derives
        comes from the path and the project root:

        * `level` is the folder's depth plus one, which is just the number of
          components in the repository-relative path;
        * `file_tree_mount_folder` is the basename of the input path, which
          here is the repository root -- so it changes with the checkout's
          directory name, and must not be hard-coded;
        * the assets and output paths are joins of those two.

        The `_assets` branch uses "/".join where the other uses os.path.join,
        which is upstream's own asymmetry and is preserved deliberately: on
        POSIX they agree, and diverging from the source would make the contract
        that compares the two harder to read, not easier.
        """
        relative = self._relative(path)
        mount = self.root.name
        directory = "" if str(relative.parent) == "." else str(relative.parent)
        output_dir_rel = SDocRelativePath(
            os.path.join(mount, directory) if directory else mount
        )
        return DocumentMeta(
            level=len(relative.parts),
            file_tree_mount_folder=mount,
            document_filename=path.name,
            document_filename_base=path.stem,
            input_doc_full_path=str(path),
            input_doc_rel_path=SDocRelativePath(str(relative)),
            input_doc_dir_rel_path=SDocRelativePath(directory),
            input_doc_assets_dir_rel_path=SDocRelativePath(
                os.path.join(mount, directory, "_assets")
                if directory
                else "/".join((mount, "_assets"))
            ),
            output_document_dir_full_path=os.path.join(
                self.config.export_output_html_root, output_dir_rel.relative_path
            ),
            output_document_dir_rel_path=output_dir_rel,
        )

    def _resolve_grammar(self, document: SDocDocument) -> None:
        """Point a freshly parsed document's grammar at the shared elements.

        The reader leaves `[GRAMMAR] IMPORT_FROM_FILE` unresolved -- a name and
        no elements -- and the index builder is what turns it into the parsed
        grammar. This is that step, over the grammars the held tree already
        parsed, for one document.

        `update_with_elements` re-parents every element in the SHARED list to
        this grammar. That is upstream's own call and upstream's own side
        effect: the loader runs it once per document over the same list, so
        after any load those parents point at whichever document happened to be
        processed last. Nothing may depend on which one -- and nothing does,
        because the only reader of a grammar element's parent is
        validate_grammar_element, which our write path does not reach.
        """
        grammar = document.grammar
        if grammar is None or grammar.import_from_file is None:
            return
        alias = grammar.import_from_file
        if alias.startswith("@"):
            filename = self.config.grammars.get(alias)
            if filename is None:
                raise SdocError(
                    f"the project config declares no grammar alias {alias!r}; "
                    f"it has {', '.join(sorted(self.config.grammars)) or '(none)'}"
                )
        else:
            filename = posixpath.join(
                document.meta.input_doc_dir_rel_path.relative_path_posix, alias
            )
        source = self.index.document_tree.get_grammar_by_filename(filename)
        if source is None:
            raise SdocError(
                f"the grammar file {filename!r} that {alias!r} names is not in "
                f"the loaded tree"
            )
        grammar.update_with_elements(source.elements)
        if not grammar.has_text_element():
            grammar.add_element_first(
                DocumentGrammar.create_default_text_element(
                    grammar, enable_mid=document.config.enable_mid is True
                )
            )
        grammar.parent = document

    def add_node(
        self,
        document: SDocDocument,
        tag: str,
        values: dict[str, str],
        relations: list[RelationSpec | tuple],
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
        for relation in relations:
            node.relations.append(
                self._build_reference(node, element, RelationSpec(*relation))
            )
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
            # A document built by new_document has never touched the disk, so
            # its directory may not exist yet and mkstemp would fail on it.
            # Made here rather than at creation time, so a refused create --
            # and a --dry-run -- leave the tree exactly as they found it.
            path.parent.mkdir(parents=True, exist_ok=True)
            # A UNIQUE temp name, not a deterministic one. Two writers on the
            # same file -- a second scribe process, or fp-accept alongside one
            # -- collided on a fixed `.<name>.sdoc-tmp`: one got ENOENT from
            # replace() and the other read a half-written file. Hidden prefix
            # so a crashed run cannot strand a visible sibling that a
            # whole-project `strictdoc export .` would try to parse.
            handle, temporary_name = tempfile.mkstemp(
                dir=path.parent, prefix=f".{path.name}.", suffix=".sdoc-tmp"
            )
            temporary = Path(temporary_name)
            try:
                with os.fdopen(handle, "w", encoding="utf8") as stream:
                    stream.write(content)
                os.chmod(temporary, 0o644)
                temporary.replace(path)
            except BaseException:
                temporary.unlink(missing_ok=True)
                raise
            written.append(path)
        self._dirty.clear()
        self._removed.clear()
        return written


def field_value(node: SDocNode, name: str) -> str | None:
    """A field's text, or None when the node does not carry it.

    get_field_by_name raises on an absent field, and absence is ordinary
    here: DEPTH is on every type but DECISION and STATUS on DECISION alone, so every
    caller iterating over both needs this guard.
    """
    if name not in node.ordered_fields_lookup:
        return None
    return node.get_field_by_name(name).get_text_value()


def file_path_of(relation: FileReference) -> str:
    """The repository-relative path a File relation names."""
    return relation.get_posix_path()


_EXPORT_PATCHED = False


def carry_file_element_into_json() -> None:
    """Make strictdoc's JSON export carry ELEMENT and ID (idempotent).

    JSONGenerator._write_requirement_relations reads exactly TYPE, FORMAT,
    VALUE and LINE_RANGE off a FileReference (json_generator.py:305-323):
    ELEMENT and ID are dropped, so an element-grained relation exports as a
    whole-file one and every downstream consumer -- the board included --
    sees a coarser graph than the corpus declares.

    The fields are read back off the FileEntry objects the generator is
    already walking, so this is the GRAPH's own data rather than a second
    derivation of it. The zip is positionally safe: that function appends
    exactly one dict per relation, in node.relations order.

    Patched HERE rather than in the strictdoc package because
    overlays/dev-tools/strictdoc.nix re-exports upstream's derivation
    unchanged for cache-hit parity -- a patched package would break that
    premise. The cost is that `strictdoc export` run by hand still drops the
    fields; only an export that goes through this module carries them.

    Fails closed: a renamed or re-shaped upstream method raises naming this
    file, rather than leaving a silently unpatched exporter behind.
    """
    global _EXPORT_PATCHED
    if _EXPORT_PATCHED:
        return
    from strictdoc.backend.json.json_generator import JSONGenerator

    original = inspect.getattr_static(JSONGenerator, "_write_requirement_relations", None)
    if not isinstance(original, staticmethod):
        raise SdocError(
            "strictdoc's JSONGenerator._write_requirement_relations is no longer a "
            "staticmethod -- dev/scripts/sdoc_model.py carry_file_element_into_json "
            "needs re-deriving from strictdoc/backend/json/json_generator.py"
        )
    unwrapped = original.__func__

    def with_file_element(node: SDocNode):
        relations = unwrapped(node)
        for exported, relation in zip(relations, node.relations):
            if not isinstance(relation, FileReference):
                continue
            for name, value in file_entry_of(relation).items():
                if value and name != "line_range":
                    exported[name.upper()] = value
        return relations

    JSONGenerator._write_requirement_relations = staticmethod(with_file_element)
    _EXPORT_PATCHED = True


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
