"""Map a StrictDoc JSON export onto the contract's candidate shape.

    python3 -m sdoc_semantics.export --export INDEX --bundle BUNDLE
        [--out OUT] [--created UID ...]

StrictDoc's own parser reads the corpus; this module only renames what that
parser reports. ``strictdoc export --formats=json`` writes one
``json/index.json``, and ``export-candidate.sh`` runs that command and feeds its
output here.

The module imports nothing from the rest of the package. The evaluator and the
exporter must be able to disagree about a candidate, which they cannot do while
they share a reader, so the bundle is read here with plain ``json`` rather than
through ``loading.py``.

Two things come out of the bundle and nothing else does. The model name is the
``model`` declaration's name. The per-element field order and the declared
relations are the bundle's grammar section. The export's own grammar section is
read for one narrow purpose, deciding whether an undeclared field is a native
runtime field or a defect; see ``_fields``.

Exit codes: 0 when a candidate was written, 2 when the export and the bundle
disagree and no candidate can be written.
"""

import argparse
import json
import pathlib
import sys

# Node types StrictDoc uses for document structure. They carry no semantic
# record, so they contribute nothing to the candidate, and a nested modeled node
# beneath one is still collected.
STRUCTURAL_NODE_TYPES = frozenset({"DOCUMENT", "SECTION", "TEXT"})

# Node keys that hold structure rather than a field value. Keys beginning with
# an underscore are metadata, which the export states itself in its _COMMENT:
# "Fields with _ are metadata."
STRUCTURE_KEYS = frozenset({"NODES", "RELATIONS"})

# The export spells a relation's direction as its StrictDoc TYPE; the contract
# spells it lowercase (contract.md:441-443).
DIRECTION_OF_RELATION_TYPE = {"Parent": "parent", "Child": "child"}

# A file relation names a path, not a record uid, so it is not an owned
# occurrence of any declared relation and is dropped rather than rejected. The
# export spells the occurrence's type File; a bundle grammar spells the
# declaration's native key file, and that declaration is dropped for the same
# reason its occurrences are.
FILE_RELATION_TYPE = "File"
FILE_RELATION_DECLARATION = "file"


class ExportError(ValueError):
    """The export and the bundle disagree, so no candidate can be written."""


def candidate_from_export(export, bundle, created=()):
    """Return the candidate object for one decoded export and one bundle.

    Records come out in StrictDoc's own order: documents in export order, and
    within each document its nodes in authored order.
    """
    elements = semantic_elements(bundle)
    records = []
    document_of_uid = {}
    for document in export.get("DOCUMENTS", []):
        title = _document_title(document)
        native_titles = native_field_titles(document)
        for node in _nodes_in_order(document.get("NODES", [])):
            record = _record(node, title, elements, native_titles)
            if record is None:
                continue
            first = document_of_uid.get(record["uid"])
            if first is not None:
                raise ExportError(
                    "The %s uid appears in both the %s document and the %s "
                    "document, and a uid is unique across the model."
                    % (record["uid"], first, title)
                )
            document_of_uid[record["uid"]] = title
            records.append(record)
    return {
        "model": model_name(bundle),
        "records": records,
        "created": created_uids(created),
    }


def model_name(bundle):
    """Return the one model name the bundle declares."""
    declarations = _declarations(bundle)
    names = [
        declaration.get("name")
        for declaration in declarations
        if declaration.get("kind") == "model"
    ]
    if len(names) != 1:
        raise ExportError(
            "The bundle declares %d models, and a candidate names exactly one."
            % len(names)
        )
    if not isinstance(names[0], str) or not names[0]:
        raise ExportError("The bundle's model declaration carries no name.")
    return names[0]


def semantic_elements(bundle):
    """Index the bundle's grammar by element tag.

    Each entry carries the field titles in grammar order, the field titles as a
    set, the declared owned occurrences as (direction, role) pairs, and the
    reverse labels as (direction, label) to the role they mirror. The reverse
    labels are indexed so that a reverse label arriving as an occurrence can be
    named in the error rather than reported as an unknown role.
    """
    grammar = bundle.get("grammar")
    if not isinstance(grammar, list):
        raise ExportError("The bundle has no grammar section to read.")
    elements = {}
    for entry in grammar:
        tag = entry.get("tag")
        if not isinstance(tag, str) or not tag:
            raise ExportError("A bundle grammar entry carries no tag.")
        field_order = [
            _titled_body(field, "field", tag)["title"]
            for field in entry.get("fields", [])
        ]
        occurrences = set()
        reverse_labels = {}
        for relation in entry.get("relations", []):
            direction, body = _sole_entry(relation, "relation", tag)
            if direction == FILE_RELATION_DECLARATION:
                continue
            role = body.get("role")
            if not isinstance(role, str) or not role:
                raise ExportError(
                    "A %s relation declaration on %s carries no role."
                    % (direction, tag)
                )
            occurrences.add((direction, role))
            reverse = body.get("reverseRole")
            if isinstance(reverse, str) and reverse:
                reverse_labels[(direction, reverse)] = role
        elements[tag] = {
            "field_order": field_order,
            "field_titles": frozenset(field_order),
            "occurrences": occurrences,
            "reverse_labels": reverse_labels,
        }
    return elements


def native_field_titles(document):
    """Return {node type: field titles} from one export document's grammar.

    This is the native grammar, not the semantic one. A field it declares that
    the bundle does not is a runtime field the candidate never carries, such as
    AUTHORED_BY; a field neither declares is a defect.
    """
    titles = {}
    grammar = document.get("GRAMMAR")
    if not isinstance(grammar, dict):
        return titles
    for element in grammar.get("ELEMENTS", []):
        node_type = element.get("NODE_TYPE")
        if not isinstance(node_type, str):
            continue
        titles[node_type] = frozenset(
            field["TITLE"]
            for field in element.get("FIELDS", [])
            if isinstance(field.get("TITLE"), str)
        )
    return titles


def created_uids(created):
    """Validate the caller's created list, which defaults to empty.

    Newness is batch information the caller supplies (contract.md:445-447), and
    an exporter of a settled corpus has none, so the default is an empty list. A
    created uid need not appear in the records: the contract keeps uids that were
    allocated and then deleted before the final state.
    """
    uids = list(created)
    for uid in uids:
        if not isinstance(uid, str) or not uid:
            raise ExportError("Every created uid must be a nonempty string.")
    repeated = sorted({uid for uid in uids if uids.count(uid) > 1})
    if repeated:
        raise ExportError(
            "The created list repeats %s, and created is duplicate-free "
            "(contract.md:445-447)." % ", ".join(repeated)
        )
    return uids


def _record(node, document_title, elements, native_titles):
    """Return one record, or None when the node carries no semantic record."""
    element = node.get("_NODE_TYPE")
    if not isinstance(element, str) or not element:
        raise ExportError(
            "A node in the %s document reports no _NODE_TYPE, so its element "
            "cannot be named." % document_title
        )
    if element in STRUCTURAL_NODE_TYPES:
        return None
    declared = elements.get(element)
    if declared is None:
        raise ExportError(
            "The %s document holds a %s node, which the bundle does not declare "
            "as an element. Emitting it would make the candidate an input error "
            "and dropping it would shrink the corpus silently "
            "(contract.md:447-448)." % (document_title, element)
        )
    uid = node.get("UID")
    if not isinstance(uid, str) or not uid:
        raise ExportError(
            "A %s node in the %s document carries no UID, and every record uid "
            "is a nonempty string (contract.md:434-435)."
            % (element, document_title)
        )
    where = "The %s node %s in the %s document" % (element, uid, document_title)
    return {
        "uid": uid,
        "element": element,
        "fields": _fields(node, where, element, declared, native_titles),
        "relations": _relations(node, where, element, declared),
    }


def _fields(node, where, element, declared, native_titles):
    """Map the node's declared fields, in the bundle's grammar order.

    A field the bundle declares and the node carries becomes a one-item list of
    the value exactly as StrictDoc reports it (contract.md:436-437). A field the
    bundle does not declare is dropped when the native grammar declares it and
    rejected otherwise.
    """
    native = native_titles.get(element, frozenset())
    for key in node:
        if key.startswith("_") or key in STRUCTURE_KEYS:
            continue
        if key in declared["field_titles"] or key in native:
            continue
        raise ExportError(
            "%s carries a %s field, which neither the bundle nor the document "
            "grammar declares for %s." % (where, key, element)
        )
    fields = {}
    for title in declared["field_order"]:
        if title not in node:
            continue
        fields[title] = _native_values(node[title], title, where)
    return fields


def _native_values(value, title, where):
    """Return one field's native strings as the contract's list.

    The value is whatever StrictDoc's parser reports, which is what the
    contract asks for: fields hold native strings exactly as authored
    (contract.md:490-491). StrictDoc's block form carries the newlines it
    encloses, so ``AUTHORED_BY: >>>\nllm\n<<<`` reports ``"llm\n"`` and not
    ``"llm"``. field-value compares native strings exactly
    (contract.md:308-309), so a leaf naming ``llm`` never matches a field
    authored in the block form. Write such a field on one line, or name the
    newline in the leaf.
    """
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        for item in value:
            if not isinstance(item, str):
                raise ExportError(
                    "%s reports a non-string inside its %s field, and a field "
                    "holds native strings only." % (where, title)
                )
        return list(value)
    raise ExportError(
        "%s reports its %s field as %s, not a native string."
        % (where, title, type(value).__name__)
    )


def _relations(node, where, element, declared):
    """Map the node's owned occurrences, in authored order.

    StrictDoc lists a relation on the owning node only, so nothing here is a
    reverse label and nothing needs stripping; a reverse label arriving anyway is
    rejected by name (contract.md:443-444). Duplicate identical occurrences are
    kept as authored (contract.md:444-445).
    """
    occurrences = node.get("RELATIONS", [])
    if not isinstance(occurrences, list):
        raise ExportError(
            "%s reports RELATIONS as %s, not a list."
            % (where, type(occurrences).__name__)
        )
    relations = []
    for occurrence in occurrences:
        relation_type = occurrence.get("TYPE")
        if relation_type == FILE_RELATION_TYPE:
            continue
        direction = DIRECTION_OF_RELATION_TYPE.get(relation_type)
        if direction is None:
            raise ExportError(
                "%s has a relation of type %r, which is neither Parent, Child "
                "nor File." % (where, relation_type)
            )
        role = occurrence.get("ROLE")
        if not isinstance(role, str) or not role:
            raise ExportError(
                "%s has a %s relation with no ROLE, so it names no declared "
                "relation." % (where, direction)
            )
        target = occurrence.get("VALUE")
        if not isinstance(target, str) or not target:
            raise ExportError(
                "%s has a %s %s relation with no VALUE, so it names no target "
                "uid." % (where, direction, role)
            )
        if (direction, role) not in declared["occurrences"]:
            mirrored = declared["reverse_labels"].get((direction, role))
            if mirrored is not None:
                raise ExportError(
                    "%s has a %s relation labelled %s, which is the reverse "
                    "label of %s; a reverse label is never an occurrence "
                    "(contract.md:443-444)."
                    % (where, direction, role, mirrored)
                )
            raise ExportError(
                "%s has a %s relation labelled %s, which the bundle does not "
                "declare for %s." % (where, direction, role, element)
            )
        relations.append({"role": role, "direction": direction, "target": target})
    return relations


def _nodes_in_order(nodes):
    """Yield every node depth first, a parent before the nodes beneath it.

    A section holds its own NODES, so the walk descends rather than reading one
    level. This corpus is flat, so the descent is unexercised by it; reading one
    level would drop a nested record without saying so.
    """
    for node in nodes:
        if not isinstance(node, dict):
            raise ExportError("A node in the export is %s, not an object." % type(node).__name__)
        yield node
        nested = node.get("NODES")
        if isinstance(nested, list):
            yield from _nodes_in_order(nested)


def _document_title(document):
    title = document.get("TITLE")
    if isinstance(title, str) and title:
        return title
    return "<untitled>"


def _declarations(bundle):
    inner = bundle.get("bundle")
    declarations = inner.get("declarations") if isinstance(inner, dict) else None
    if not isinstance(declarations, list):
        raise ExportError("The bundle has no declarations to read.")
    return declarations


def _titled_body(declaration, what, tag):
    _, body = _sole_entry(declaration, what, tag)
    title = body.get("title")
    if not isinstance(title, str) or not title:
        raise ExportError("A %s declaration on %s carries no title." % (what, tag))
    return body


def _sole_entry(declaration, what, tag):
    """Return the one (key, body) pair of a single-key bundle declaration."""
    if not isinstance(declaration, dict) or len(declaration) != 1:
        raise ExportError(
            "A %s declaration on %s is not a single-key object." % (what, tag)
        )
    key = next(iter(declaration))
    body = declaration[key]
    if not isinstance(body, dict):
        raise ExportError("A %s declaration on %s carries no body." % (what, tag))
    return key, body


def main(argv=None):
    parsed = _parser().parse_args(argv)
    try:
        candidate = candidate_from_export(
            _read_json(parsed.export),
            _read_json(parsed.bundle),
            _flattened(parsed.created),
        )
    except (OSError, ValueError) as problem:
        sys.stderr.write("sdoc_semantics.export: %s\n" % problem)
        return 2
    text = json.dumps(candidate, indent=2, ensure_ascii=False) + "\n"
    if parsed.out in (None, "-"):
        sys.stdout.write(text)
    else:
        pathlib.Path(parsed.out).write_text(text, encoding="utf-8")
    return 0


def _read_json(path):
    with open(path, encoding="utf-8") as stream:
        return json.load(stream)


def _flattened(groups):
    if not groups:
        return []
    return [uid for group in groups for uid in group]


def _parser():
    parser = argparse.ArgumentParser(
        prog="python3 -m sdoc_semantics.export",
        description="Map a StrictDoc JSON export onto a contract candidate.",
    )
    parser.add_argument(
        "--export",
        required=True,
        help="Path to the json/index.json that strictdoc export wrote.",
    )
    parser.add_argument(
        "--bundle",
        required=True,
        help="Path to bundle.json, which names the model and its grammar.",
    )
    parser.add_argument(
        "--out",
        default=None,
        help="Write the candidate here; - or omitted writes to stdout.",
    )
    parser.add_argument(
        "--created",
        action="append",
        nargs="+",
        metavar="UID",
        default=None,
        help=(
            "Uids newly allocated during this batch. Repeatable, and each use "
            "takes one or more uids. The default is an empty created list."
        ),
    )
    return parser


if __name__ == "__main__":
    sys.exit(main())
