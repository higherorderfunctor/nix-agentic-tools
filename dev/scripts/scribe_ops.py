#!/usr/bin/env python3
# cspell:ignore sdoc uids sgra precheck prechecks argparse unrelate
"""The typed operations a scribe client asks for
(MECH-SCRIBE-COMMANDS-LOAD-IN-PROCESS, docs/plans/scribe-daemon/).

THE DAEMON DOES NOT KNOW ABOUT ARGV. A client parses its own command line --
it can, because the option surface comes from the grammar FILE and needs no
corpus (see scribe_grammar.py) -- and sends an operation:

    {"op": "set", "uid": "MECH-X", "fields": {"DEPTH": "sketch"}}

Validation against the grammar happens here, against the graph the daemon
already holds. A field illegal for that node's type is refused here, with the
type resolved from the index rather than guessed from the UID prefix, which
is a birth-name and not a type.

WRITES GO TO THE MODEL, READS REUSE THE RENDERER
-------------------------------------------------
Writes call sdoc_model.Graph directly. They deliberately do NOT go through
sdoc_cli's handlers, because those re-read every value through `read_value`,
which treats a leading `@` as a file path -- correct for a command line,
wrong for a value a client already resolved.

Reads call sdoc_cli's do_show / do_list / do_check, which are pure rendering
over a graph. Reimplementing them would be duplication; calling them with
named values rather than a parsed argv is not.
"""

from __future__ import annotations

import contextlib
import io
import sys
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent))

import sdoc_cli  # noqa: E402
from scribe_diff import unified_pending_diff  # noqa: E402
from scribe_workspace import (  # noqa: E402
    Workspace,
    WorkspaceError,
    refuse_dangling_links,
    refuse_if_referenced,
)
from sdoc_model import (  # noqa: E402
    RelationSpec,
    SdocError,
    relation_role,
    validate_guarded,
)

READS = ("show", "list", "check")
WRITES = ("new", "set", "relate", "unrelate", "move", "delete")
OPERATIONS = READS + WRITES

# MECH-RUNTIME-WRITE-GUARD. Named here as well as in the command line,
# because a typed client is a second door onto the same pipeline and a guard
# on only one door is not a guard.
GUARDED = ("AUTHORED_BY", "PARENT_FP")


def _guard(fields: dict) -> None:
    named = [f for f in fields if f.upper() in GUARDED]
    if named:
        raise SdocError(
            f"{', '.join(named)} is the operator's to set, not the writer's; "
            f"there is deliberately no way to pass it"
        )


def _known_fields(graph, tag: str) -> dict:
    return {field.title: field for field in graph.element(tag).fields}


def _check_fields(graph, tag: str, fields: dict) -> None:
    """Every field must be declared by THIS type, and every choice value must
    be one of that field's words. The asymmetry is the point: a DECISION has
    no DEPTH, so `--depth` on one is an error rather than a silent no-op."""
    declared = _known_fields(graph, tag)
    for name, value in fields.items():
        field = declared.get(name)
        if field is None:
            raise SdocError(
                f"{tag} declares no field {name}; it has "
                f"{', '.join(sorted(declared))}"
            )
        options = list(getattr(field, "field_options", None) or [])
        if options and value not in options:
            raise SdocError(f"{name} on {tag} must be one of {', '.join(options)}, not {value!r}")


def _render(handler, graph, root: Path, **named) -> str:
    """Call a rendering handler with named values instead of a parsed argv."""
    out = io.StringIO()
    err = io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        handler(graph, SimpleNamespace(**named), root)
    return out.getvalue() or err.getvalue()


def apply(workspace: Workspace, op: str, params: dict) -> dict:
    """Run one operation. Raises SdocError or WorkspaceError to refuse."""
    if op not in OPERATIONS:
        raise SdocError(f"unknown operation {op!r}; expected one of {', '.join(OPERATIONS)}")

    if op in READS:
        graph = workspace.current().graph
        validate_guarded(graph)
        root = workspace.root
        if op == "show":
            return {"text": _render(sdoc_cli.do_show, graph, root, uid=_need(params, "uid"))}
        if op == "list":
            return {
                "text": _render(
                    sdoc_cli.do_list, graph, root,
                    node_type=params.get("type"),
                    depth=params.get("depth"),
                    status=params.get("status"),
                )
            }
        return {"text": _render(sdoc_cli.do_check, graph, root)}

    graph = workspace._held()
    validate_guarded(graph)
    fields = dict(params.get("fields") or {})
    _guard(fields)
    dry_run = bool(params.get("dry_run", False))

    if op == "new":
        return _new(workspace, params, fields, dry_run=dry_run)

    uid = _need(params, "uid")
    if not graph.has_node(uid):
        raise SdocError(f"{uid} is not a node in the graph")
    tag = graph.node(uid).node_type

    if op == "set":
        _check_fields(graph, tag, fields)
        unset = list(params.get("unset") or [])
        _guard({name: "" for name in unset})
        if not fields and not unset:
            raise SdocError("nothing to set -- pass at least one field or an unset")

        def mutate(g):
            for name, value in fields.items():
                g.set_field(uid, name, value)
            for name in unset:
                g.set_field(uid, name, None)

        return _written(workspace, mutate, refuse_dangling_links, dry_run=dry_run)

    if op in ("relate", "unrelate"):
        # `File` is the role a client NAMES and the empty string is the role
        # the grammar declares. This branch used to pass the client's spelling
        # straight through, so every File relation through the daemon was
        # refused as a role the type does not declare, while the same verb on
        # the command line worked (WORK-SCRIBE-RELATE-FILE-ROLE). The mapping
        # now lives once, in sdoc_model.relation_role.
        spec = _relation_spec(params)
        return _written(
            workspace,
            lambda g: (g.add_relation if op == "relate" else g.remove_relation)(
                uid,
                spec.role,
                spec.target,
                file_element=spec.element,
                file_id=spec.id,
                line_range=spec.line_range,
            ),
            refuse_dangling_links if op == "relate" else None,
            dry_run=dry_run,
        )

    if op == "delete":
        return _written(
            workspace,
            lambda g: g.remove_node(uid),
            refuse_if_referenced(uid),
            dry_run=dry_run,
        )

    if op == "move":
        destination = sdoc_cli.target_path(_need(params, "path"), uid, workspace.root)
        return _move(workspace, uid, destination, dry_run=dry_run)

    raise SdocError(f"operation {op!r} is not implemented")


def _relation_spec(params: dict) -> RelationSpec:
    """One relation off the wire, with the File role mapped and the
    element-grained slots carried. Shared by relate/unrelate and by `new`,
    so the two doors onto the same pipeline cannot drift again."""
    return RelationSpec(
        relation_role(_need(params, "role")),
        _need(params, "target"),
        params.get("element") or None,
        params.get("id") or None,
        params.get("line_range") or params.get("lineRange") or None,
    )


def _need(params: dict, name: str):
    value = params.get(name)
    if value in (None, ""):
        raise SdocError(f"{name} is required")
    return value


def _written(workspace: Workspace, mutate, precheck, *, dry_run: bool) -> dict:
    result = workspace.write(mutate, precheck=precheck, dry_run=dry_run)
    response = {
        "written": [str(path.relative_to(workspace.root)) for path in result.written]
    }
    if dry_run:
        response["text"] = unified_pending_diff(result.pending, workspace.root)
    return response


def _new(workspace: Workspace, params: dict, fields: dict, *, dry_run: bool) -> dict:
    """Create a node in a file of its own -- an ordinary deferred write.

    The document is built in memory by Graph.new_document, so this goes
    through workspace.write() like every other verb and defers its reload.
    It used to write a header-only skeleton to disk and re-read the whole
    corpus, to resolve the `@repo` alias on the file it had just created:
    about 780 ms per node, against 6 ms for a set.

    The checks that can be answered without mutating anything stay OUT of the
    write, deliberately. A refusal raised inside `mutate` discards the held
    graph, so the next read pays a reload for a create that never began.
    """
    graph = workspace._held()
    tag = _need(params, "type")
    if tag not in graph.tags():
        raise SdocError(f"unknown node type {tag!r}; expected one of {', '.join(graph.tags())}")
    uid = _need(params, "uid")
    sdoc_cli.check_prefix(graph, tag, uid)
    if graph.has_node(uid):
        raise SdocError(f"{uid} already exists at {graph.path_of(graph.node(uid))}")
    _check_fields(graph, tag, fields)
    values = dict(fields)
    values["UID"] = uid  # a field to the model, a parameter on the wire
    values["AUTHORED_BY"] = "llm"  # MECH-RUNTIME-WRITE-GUARD

    relations = [_relation_spec(r) for r in (params.get("relations") or [])]
    path = sdoc_cli.target_path(_need(params, "path"), uid, workspace.root)
    if path.exists():
        raise SdocError(f"{path} already exists")

    def mutate(g):
        g.add_node(g.new_document(path, values.get("TITLE", uid)), tag, values, relations)

    return _written(workspace, mutate, refuse_dangling_links, dry_run=dry_run)


def _move(workspace: Workspace, uid: str, destination: Path, *, dry_run: bool) -> dict:
    graph = workspace._held()
    node = graph.node(uid)
    document = node.get_document()
    source = graph.path_of(node)
    if destination.exists():
        raise WorkspaceError(f"{destination} already exists")

    # A move does not rewrite the document, but it still crosses the same
    # validation boundary as every other writing verb. Touching the held
    # document makes Workspace render and reparse it; dry_run=True then drops
    # that speculative dirty state before either branch below can reach disk.
    workspace.write(lambda g: g._touch(document), dry_run=True)
    if dry_run:
        return {
            "text": (
                f"move {source.relative_to(workspace.root)} -> "
                f"{destination.relative_to(workspace.root)}\n"
            ),
            "written": [],
        }
    destination.parent.mkdir(parents=True, exist_ok=True)
    source.rename(destination)
    workspace._discard()
    return {"written": [str(destination.relative_to(workspace.root))]}
