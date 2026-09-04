#!/usr/bin/env python3
# cspell:ignore uids sdoc unrelate parallelizer keepends tofile
"""sdoc -- the command-line tool that writes .sdoc files (SLICE-SDOC-CLI,
docs/plans/strictdoc-tooling/slice-sdoc-cli.sdoc).

THE OPTION SURFACE IS DERIVED FROM THE GRAMMAR, not typed by a person. One
flag per field a node type declares, one per relation role it may make, and
every choice flag's word list read off that field. The types are
genuinely asymmetric -- a DECISION carries no DEPTH and no File relation, a
DECISION is the only type with a STATUS; the rest carry DEPTH, so the surface differs
under the same name, an INVARIANT cannot point at a file -- and that
asymmetry is exactly what gets hand-written wrong. Run
`sdoc new NARRATIVE --help` and `sdoc new DECISION --help` to see two different
surfaces come out of one grammar.

    writing   new  set  relate  unrelate  move  delete
    reading   show  list  check

Every writing verb loads the whole graph, applies the change in memory,
validates the node against the grammar, writes, and then RELOADS to prove
the graph still parses -- restoring the original bytes if it does not. A
command that cannot validate does not leave a changed file behind. Every
writing verb takes --dry-run and prints the diff instead.

NO SEMANTIC RULES APPLY AT THIS MILESTONE, and that is the scope boundary.
This tool enforces exactly what the GRAMMAR says: the node types, which
fields are required, each choice field's word list, and which relation roles
a type may declare. It enforces nothing about how this instance USES them.
Who may sign, whether DEPTH may regress, and when deleting is legitimate are
instance semantics, and SLICE-INSTANCE-SEMANTICS-MIGRATION is where they get
written.

Two rules here are NOT instance semantics and are enforced:

* UIDs are passed in and never minted -- they are hand-chosen and semantic by
  the operator's 2026-08-27 ruling (DEC-NODE-FILE-NAMING), so there is no
  auto-uid path. A UID whose prefix does not match its node type is refused;
  the grammar declares the prefix, and strictdoc itself does not check it (a
  MECHANISM named SLICE-... exports exit 0 today).
* AUTHORED_BY and PARENT_FP have no flags at all -- see
  MECH-RUNTIME-WRITE-GUARD. `new` writes AUTHORED_BY: llm unconditionally.

`delete` exists and the sdoc skill deliberately does not teach it.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from scribe_diff import unified_pending_diff  # noqa: E402
from sdoc_model import (  # noqa: E402
    FILE_ELEMENTS,
    GUARDED_FIELDS,
    GUARDED_OWNERS,
    RelationSpec,
    SdocError,
    field_value,
    validate_guarded,
    file_entry_of,
    file_path_of,
    normalize_file_value,
    open_graph,
    relation_role,
    roles_of,
)

CONFIG_MARKER = "strictdoc_config.py"

WRITING_VERBS = ("new", "set", "relate", "unrelate", "move", "delete")

# Verbs whose FIRST positional is a UID, and whose flag surface therefore
# depends on that UID's node type. Peeked out of argv before the real parser
# is built -- see resolve_type_from_argv.
UID_FIRST_VERBS = ("set", "relate", "unrelate", "move", "delete", "show")


def flag_for(field: str) -> str:
    """UID -> --uid, RETIRES_ON -> --retires-on. The grammar names fields in
    SCREAMING_SNAKE and argparse wants a long option."""
    return "--" + field.lower().replace("_", "-")


def find_root(start: Path) -> Path:
    """Walk up for strictdoc_config.py. There is exactly one, at the
    repository root, so that plan documents, settled architecture and any
    future source-extracted nodes land in ONE graph and can cite each
    other."""
    for candidate in [start, *start.parents]:
        if (candidate / CONFIG_MARKER).is_file():
            return candidate
    raise SdocError(
        f"no {CONFIG_MARKER} in {start} or any parent -- run inside the "
        f"repository, or pass --root"
    )


def read_value(raw: str) -> str:
    """A field value, or `@path` to read one from a file, or `-` for stdin.

    STATEMENT and NOTES are multi-paragraph prose in this corpus; typing
    that through a shell argument is where the quoting accidents live.
    """
    if raw == "-":
        return sys.stdin.read().rstrip("\n")
    if raw.startswith("@"):
        path = Path(raw[1:])
        if not path.is_file():
            raise SdocError(f"{path} is not a readable file")
        return path.read_text(encoding="utf8").rstrip("\n")
    return raw


def reject_guarded(argv: list[str]) -> None:
    """MECH-RUNTIME-WRITE-GUARD: naming a guarded field exits non-zero
    saying who owns it.

    There is no flag to pass, so argparse would answer `unrecognized
    arguments` -- which reads as a typo rather than as a refusal. This is
    the only place the guard is spoken; what ENFORCES it is that no code
    path below emits either field.
    """
    for field in GUARDED_FIELDS:
        flag = flag_for(field)
        for token in argv:
            if token == flag or token.startswith(flag + "="):
                raise SdocError(
                    f"{flag} is not a flag of this tool. {field} is written by "
                    f"{GUARDED_OWNERS[field]}. There is no override: a flag the "
                    f"model can pass is a document rule wearing a different hat."
                )


def split_root(argv: list[str]) -> tuple[str | None, list[str]]:
    """Pull `--root VALUE` out of argv, returning it and the rest.

    Both the verb peek and main need it, and they must agree: a peek that
    does not know --root consumes a value treats that VALUE as the verb, so
    `sdoc --root . set MECH-X --depth ...` resolved no node type and built a
    `set` parser with no field flags. The failure surfaced as argparse's
    "unrecognized arguments: --depth", which points at the wrong thing
    entirely.
    """
    rest: list[str] = []
    root: str | None = None
    index = 0
    while index < len(argv):
        token = argv[index]
        if token == "--root":
            if index + 1 >= len(argv):
                raise SdocError("--root needs a path")
            root = argv[index + 1]
            index += 2
            continue
        if token.startswith("--root="):
            root = token.split("=", 1)[1]
            index += 1
            continue
        rest.append(token)
        index += 1
    return root, rest


def resolve_type_from_argv(argv: list[str], graph) -> tuple[str | None, str | None]:
    """(verb, node type) peeked out of argv so the parser can be built with
    exactly one type's fields and roles.

    For `new` the type is written out. For the UID-first verbs it is
    resolved from the UID's prefix, which is the same prefix-to-type
    agreement the tool enforces on write.
    """
    tokens = [token for token in argv if token != "--"]
    verb = next((token for token in tokens if not token.startswith("-")), None)
    if verb is None:
        return None, None
    index = tokens.index(verb)
    following = tokens[index + 1] if index + 1 < len(tokens) else None
    if verb == "new":
        return verb, following
    if verb in UID_FIRST_VERBS and following and not following.startswith("-"):
        # DEC-UID-OUTLIVES-TYPE: an existing node's type is its element tag,
        # never its prefix -- retyped nodes keep the prefix they were born
        # with. The prefix decides only when the UID is not (yet) in the graph.
        if graph.has_node(following):
            return verb, graph.node(following).node_type
        for tag in graph.tags():
            if following.startswith(graph.element(tag).property_prefix):
                return verb, tag
    return verb, None


def check_prefix(graph, tag: str, uid: str) -> None:
    """A NEW node must carry its element's current prefix."""
    prefix = graph.element(tag).property_prefix
    if not uid.startswith(prefix):
        raise SdocError(
            f"{uid!r} is not a {tag} name: the grammar gives {tag} the prefix "
            f"{prefix!r}. UIDs are hand-chosen and semantic; nothing here mints one."
        )


def prefix_owner(graph, uid: str):
    """The element whose current prefix this UID carries, or None.

    None covers a retired prefix (SLICE-, INV-, SPIKE- after the 2026-08-30
    migration), which is history and not a mismatch.
    """
    for tag in graph.tags():
        if uid.startswith(graph.element(tag).property_prefix):
            return tag
    return None


# --------------------------------------------------------------------------
# Parser, built from the grammar
# --------------------------------------------------------------------------


def add_field_flags(
    parser: argparse.ArgumentParser,
    element,
    *,
    required: bool,
    allow_existing: bool = False,
) -> None:
    """One flag per field the element declares, minus the guarded set.

    `required` distinguishes `new`, where the grammar's REQUIRED means the
    flag is mandatory, from `set`, where every field is optional because the
    caller is changing one of them.

    `allow_existing` is for the union fallback above: five types declare
    overlapping field titles, so the same flag is offered twice. The second
    offer WIDENS the first's choice list rather than being dropped, because
    STATUS carries a different word list on DECISION and on SPIKE and the
    union has to accept both -- the node's own type then rejects the wrong
    one at apply time.
    """
    for field in element.fields:
        if field.title in GUARDED_FIELDS or field.title == "MID":
            continue
        options = list(getattr(field, "options", None) or [])
        dest = f"field_{field.title}"
        existing = next((a for a in parser._actions if a.dest == dest), None)
        if existing is not None:
            if not allow_existing:
                raise SdocError(f"{field.title} offered twice on one parser")
            if existing.choices is not None and options:
                for option in options:
                    if option not in existing.choices:
                        existing.choices.append(option)
            continue
        parser.add_argument(
            flag_for(field.title),
            dest=dest,
            metavar="|".join(options) if options else "VALUE",
            choices=options or None,
            required=required and field.required,
            help=(
                f"{element.tag}.{field.title}"
                + (" (required)" if field.required else "")
                + ("" if options else "  -- @FILE reads it from a file, - from stdin")
            ),
        )


def build_parser(graph, verb: str | None, tag: str | None) -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="sdoc",
        description=__doc__.split("\n\n")[1],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--root", help="Project root (default: the tree holding strictdoc_config.py)")
    subparsers = parser.add_subparsers(dest="verb", required=True)

    def writing(name: str, help_text: str) -> argparse.ArgumentParser:
        sub = subparsers.add_parser(name, help=help_text)
        sub.add_argument(
            "--dry-run",
            action="store_true",
            help="Print the diff the command would write and change nothing",
        )
        return sub

    # new -- one subparser per node type, each with that type's own fields
    new_parser = subparsers.add_parser("new", help="Create a node in a file of its own")
    type_parsers = new_parser.add_subparsers(dest="node_type", required=True)
    for candidate in graph.tags():
        if tag is not None and candidate != tag:
            # Only the requested type is built out. Every type is still
            # listed, so `sdoc new` with no type prints every element as a choice.
            type_parsers.add_parser(candidate, help=f"Create a {candidate}")
            continue
        element = graph.element(candidate)
        type_parser = type_parsers.add_parser(
            candidate,
            help=f"Create a {candidate}",
            description=(
                f"{candidate} nodes are named {element.property_prefix}...  "
                f"Relation roles: {', '.join(roles_of(element))}"
            ),
        )
        add_field_flags(type_parser, element, required=True)
        type_parser.add_argument(
            "--path",
            required=True,
            metavar="FILE|DIR",
            help=(
                "Where to write it. A directory derives the filename from the "
                "UID, lowercased, per DEC-NODE-FILE-NAMING."
            ),
        )
        type_parser.add_argument(
            "--relate",
            action="append",
            default=[],
            metavar="ROLE=TARGET",
            help=f"Repeatable. ROLE is one of: {', '.join(roles_of(element))}",
        )
        type_parser.add_argument("--dry-run", action="store_true")

    set_parser = writing("set", "Set or unset fields on an existing node")
    set_parser.add_argument("uid", help="The node to change. Must come first.")
    # With a type resolved from the UID's prefix these are EXACTLY that type's
    # fields. Without one -- an unknown prefix, or a UID that is not first --
    # fall back to the union across types, so the command still parses and the
    # error the caller sees is "no node with UID ..." or "MECHANISM declares no
    # field ...", either of which names the actual problem. argparse's
    # "unrecognized arguments: --depth" does not.
    for element in [graph.element(tag)] if tag else [graph.element(t) for t in graph.tags()]:
        add_field_flags(set_parser, element, required=False, allow_existing=tag is None)
    unsettable = sorted(
        {
            field.title
            for element in ([graph.element(tag)] if tag else [graph.element(t) for t in graph.tags()])
            for field in element.fields
            if not field.required and field.title not in GUARDED_FIELDS
        }
    )
    set_parser.add_argument(
        "--unset",
        action="append",
        default=[],
        metavar="FIELD",
        choices=unsettable,
        help="Remove an optional field entirely. Repeatable.",
    )

    for name, help_text in (
        ("relate", "Add a relation"),
        ("unrelate", "Remove a relation"),
    ):
        relation_parser = writing(name, help_text)
        relation_parser.add_argument("uid", help="The node to change. Must come first.")
        relation_parser.add_argument(
            "--role",
            required=True,
            choices=roles_of(graph.element(tag)) if tag else None,
            help="A relation role this node type declares",
        )
        relation_parser.add_argument(
            "--target",
            required=True,
            help="A node UID, or a repository-relative path when --role File",
        )
        # Element-grained File relations. The three slots are strictdoc's,
        # not the .sgra grammar's -- a File relation is declared there by
        # TYPE alone -- so the vocabulary comes from sdoc_model, which
        # derives it from strictdoc rather than restating it.
        relation_parser.add_argument(
            "--element",
            choices=FILE_ELEMENTS,
            help=(
                "With --role File: the relation names an ITEM in the file, not the "
                "whole of it. Needs --id. The item's KIND (module, option, binding) "
                "is not spelled here -- it reaches a reader through the item's "
                "description"
            ),
        )
        relation_parser.add_argument(
            "--id",
            dest="element_id",
            help=(
                "With --element: which item, by its qualified name as the reader "
                'names it (a quoted Nix attribute keeps its quotes: tasks."build:all")'
            ),
        )
        relation_parser.add_argument(
            "--line-range",
            metavar="BEGIN-END",
            help=(
                "With --role File: the lines the relation names. Mutually exclusive "
                "with --element/--id -- strictdoc's writer emits one or the other"
            ),
        )

    move_parser = writing("move", "Move a node's file")
    move_parser.add_argument("uid")
    move_parser.add_argument("--to", required=True, metavar="FILE|DIR", help="New location")

    delete_parser = writing("delete", "Delete a node, and with it its file")
    delete_parser.add_argument("uid")

    show_parser = subparsers.add_parser("show", help="Print a node, with its relations resolved to titles")
    show_parser.add_argument("uid")

    list_parser = subparsers.add_parser("list", help="List nodes, filtered")
    list_parser.add_argument("--type", dest="node_type", choices=graph.tags())
    list_parser.add_argument("--depth")
    list_parser.add_argument("--status")

    subparsers.add_parser("check", help="Validate every node, relation and File path")
    return parser


# --------------------------------------------------------------------------
# Verbs
# --------------------------------------------------------------------------


def collect_fields(args, element) -> dict[str, str]:
    values = {}
    for field in element.fields:
        raw = getattr(args, f"field_{field.title}", None)
        if raw is not None:
            values[field.title] = read_value(raw)
    return values


def split_relate(spec: str) -> RelationSpec:
    role, separator, target = spec.partition("=")
    if not separator:
        raise SdocError(f"--relate wants ROLE=TARGET, got {spec!r}")
    return RelationSpec(relation_role(role), target)


def target_path(raw: str, uid: str, root: Path) -> Path:
    path = Path(raw)
    if not path.is_absolute():
        path = root / path
    if path.is_dir() or raw.endswith("/"):
        path = path / f"{uid.lower()}.sdoc"
    if path.suffix != ".sdoc":
        raise SdocError(f"{path} is not a .sdoc file")
    return path


def do_new(graph, args, root: Path) -> int:
    tag = args.node_type
    element = graph.element(tag)
    values = collect_fields(args, element)
    uid = values["UID"]
    check_prefix(graph, tag, uid)
    if graph.has_node(uid):
        raise SdocError(f"{uid} already exists at {graph.path_of(graph.node(uid))}")
    # MECH-RUNTIME-WRITE-GUARD: required on every type, so it cannot be
    # omitted, and there is no flag for it. An agent writes llm; the
    # operator's own authorship is an edit outside this tool.
    values["AUTHORED_BY"] = "llm"
    relations = [split_relate(spec) for spec in args.relate]

    path = target_path(args.path, uid, root)
    if path.exists():
        raise SdocError(f"{path} already exists")

    # Built in memory, so a create is a proposal like every other edit: it
    # joins pending() and reaches the disk only in save(). Nothing is written
    # by a refused create, and --dry-run now leaves no skeleton behind either.
    # Graph.new_document is where the grammar alias and the meta get resolved
    # without a reload.
    graph.add_node(graph.new_document(path, values["TITLE"]), tag, values, relations)
    return finish(graph, args, root)


def do_set(graph, args, root: Path) -> int:
    node = graph.node(args.uid)
    element = graph.element(node.node_type)
    values = collect_fields(args, element)
    if not values and not args.unset:
        raise SdocError("nothing to set -- pass at least one field flag or --unset")
    for field, value in values.items():
        graph.set_field(args.uid, field, value)
    for field in args.unset:
        graph.set_field(args.uid, field, None)
    return finish(graph, args, root)


def relation_from_args(args) -> RelationSpec:
    """The relation a relate/unrelate command line names.

    The File slots are refused OUTSIDE a File relation here rather than only
    in the model, so the message names the flag the operator typed.
    """
    role = relation_role(args.role)
    named = (args.element, args.element_id, args.line_range)
    if role and any(named):
        raise SdocError(
            f"--element, --id and --line-range name part of a FILE; "
            f"--role {args.role} relates this node to another node"
        )
    target = normalize_file_value(args.target) if role == "" else args.target
    return RelationSpec(role, target, *named)


def do_relate(graph, args, root: Path) -> int:
    spec = relation_from_args(args)
    graph.add_relation(
        args.uid,
        spec.role,
        spec.target,
        file_element=spec.element,
        file_id=spec.id,
        line_range=spec.line_range,
    )
    return finish(graph, args, root)


def do_unrelate(graph, args, root: Path) -> int:
    spec = relation_from_args(args)
    graph.remove_relation(
        args.uid,
        spec.role,
        spec.target,
        file_element=spec.element,
        file_id=spec.id,
        line_range=spec.line_range,
    )
    return finish(graph, args, root)


def do_move(graph, args, root: Path) -> int:
    node = graph.node(args.uid)
    source = graph.path_of(node)
    destination = target_path(args.to, args.uid, root)
    if destination.exists():
        raise SdocError(f"{destination} already exists")
    if args.dry_run:
        print(f"move {source.relative_to(root)} -> {destination.relative_to(root)}")
        return 0
    # Read the bytes BEFORE the rename: afterwards `source` is gone, and a
    # rollback map built from it would restore None -- that is, unlink the
    # destination and leave nothing behind.
    original = source_bytes(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    source.replace(destination)
    verify(root, restore={destination: None, source: original})
    print(f"moved {source.relative_to(root)} -> {destination.relative_to(root)}", file=sys.stderr)
    return 0


def source_bytes(path: Path) -> str | None:
    return path.read_text(encoding="utf8") if path.exists() else None


def do_delete(graph, args, root: Path) -> int:
    graph.remove_node(args.uid)
    return finish(graph, args, root)


def describe_file_relation(relation) -> str:
    """`path`, or `path > element id` when the relation names one item in
    the file. The same shape the board's card draws, so what `show` prints
    and what the app renders read alike."""
    entry = file_entry_of(relation)
    text = file_path_of(relation)
    if entry["element"] or entry["id"]:
        text += f"  > {entry['element'] or '?'} {entry['id'] or '?'}"
    if entry["line_range"]:
        text += f"  [{entry['line_range']}]"
    return text


def do_show(graph, args, _root: Path) -> int:
    node = graph.node(args.uid)
    print(graph.render(node.get_document()), end="")
    if node.relations:
        print("\n--- relations resolved ---")
        for relation in node.relations:
            uid = getattr(relation, "ref_uid", None)
            if uid is None:
                print(f"  {'File':<13} {describe_file_relation(relation)}")
                continue
            target = graph.index.get_node_by_uid_weak(uid)
            title = target.reserved_title if target is not None else "(UNRESOLVED)"
            print(f"  {relation.role:<13} {uid}  --  {title}")
    return 0


def do_list(graph, args, root: Path) -> int:
    rows = []
    for node in graph.iter_nodes():
        if args.node_type and node.node_type != args.node_type:
            continue
        fields = {name: field_value(node, name) for name in ("DEPTH", "STATUS")}
        if args.depth and fields.get("DEPTH") != args.depth:
            continue
        if args.status and fields.get("STATUS") != args.status:
            continue
        rows.append(
            (
                node.reserved_uid,
                node.node_type,
                fields.get("DEPTH") or fields.get("STATUS") or "",
                graph.path_of(node).relative_to(root),
            )
        )
    width = max((len(r[0]) for r in rows), default=0)
    for uid, node_type, state, path in sorted(rows):
        print(f"{uid:<{width}}  {node_type:<9}  {state:<17}  {path}")
    print(f"\n{len(rows)} node(s)", file=sys.stderr)
    return 0


def do_check(graph, _args, root: Path) -> int:
    """Whole-corpus pass. Not a substitute for the per-command validation --
    this catches what a write-time check structurally cannot, which is a
    file deleted or moved after its relation was written."""
    findings = []
    retyped = []
    for node in graph.iter_nodes():
        uid = node.reserved_uid
        try:
            graph.validate(node)
        except SdocError as exc:
            findings.append(f"{uid}: {exc}")
        # DEC-UID-OUTLIVES-TYPE: a prefix names the type a node was BORN with.
        # A node retyped in place keeps it, so this is a note, never a finding.
        owner = prefix_owner(graph, uid)
        if owner is not None and owner != node.node_type:
            retyped.append(f"{uid}: born {owner}, now {node.node_type}")
        for relation in node.relations:
            target_uid = getattr(relation, "ref_uid", None)
            if target_uid is None:
                value = file_path_of(relation)
                try:
                    normalize_file_value(value)
                except SdocError as exc:
                    findings.append(f"{uid}: {exc}")
                    continue
                if not (root / value).is_file():
                    findings.append(f"{uid}: File relation {value!r} names no existing file")
            elif not graph.has_node(target_uid):
                findings.append(f"{uid}: relation to {target_uid!r}, which is not in the graph")
    for note in retyped:
        print(f"NOTE {note}", file=sys.stderr)
    for finding in findings:
        print(f"FAIL {finding}", file=sys.stderr)
    total = sum(1 for _ in graph.iter_nodes())
    print(f"{total} nodes, {len(findings)} finding(s)", file=sys.stderr)
    return 1 if findings else 0


# --------------------------------------------------------------------------
# Write, then prove the graph still parses
# --------------------------------------------------------------------------


def print_diff(graph, root: Path) -> None:
    sys.stdout.write(unified_pending_diff(graph.pending(), root))


def load_graph(root: Path):
    """open_graph, with strictdoc's process exit turned into an exception.

    THIS INDIRECTION IS THE WHOLE POINT AND IT IS EASY TO LOSE.
    TraceabilityIndexBuilder.create does not RAISE on a semantic error -- it
    prints and calls sys.exit(1). Duplicate UIDs across documents, grammar
    validation and node validation all take that path. SystemExit derives
    from BaseException, not Exception, so `except Exception` around a graph
    load catches none of them, and a rollback written that way silently does
    not fire.

    Measured: with a duplicate UID landed between load and verify -- the
    ordinary shape of two agent sessions in one repository -- the write
    stayed on disk and the process exited 1 with strictdoc's bare `error:`
    line rather than the promised rollback.
    """
    try:
        return open_graph(root, output_dir=root / "output")
    except SystemExit as exc:
        raise SdocError(
            f"strictdoc could not load the graph and exited {exc.code} rather "
            f"than raising; its own message is above."
        ) from exc


def verify(root: Path, restore: dict[Path, str | None]) -> None:
    """Reload the whole graph and roll back if it no longer parses.

    validate_node is a per-node grammar check and cannot see a document
    that fails to PARSE, which is the failure this tool exists to stop. The
    reload costs about 0.25 s against a warm cache -- the price of never
    leaving a broken file behind.

    Catches BaseException rather than Exception, and the difference is not
    pedantry: see load_graph. A KeyboardInterrupt lands here too, and
    restoring on one is correct -- an interrupted write is exactly the state
    this exists to undo.
    """
    try:
        load_graph(root)
    except BaseException as exc:
        for path, original in restore.items():
            if original is None:
                path.unlink(missing_ok=True)
            else:
                path.write_text(original, encoding="utf8")
        if isinstance(exc, SdocError):
            raise SdocError(
                f"the write was rolled back: the graph no longer loads.\n{exc}"
            ) from exc
        if not isinstance(exc, Exception):
            # KeyboardInterrupt and friends: the files are restored, and the
            # caller still gets the interrupt it asked for.
            raise
        raise SdocError(
            f"the write was rolled back: the graph no longer parses.\n{exc}"
        ) from exc


def finish(graph, args, root: Path) -> int:
    # Running inside a resident workspace: it owns saving and verification,
    # and doing either here would pay the full reload the daemon exists to
    # defer. The handler has already mutated the graph, which is all the
    # workspace needs from it.
    if getattr(args, "_defer_save", False) and not getattr(args, "dry_run", False):
        return 0
    if getattr(args, "dry_run", False):
        print_diff(graph, root)
        return 0
    # source_bytes answers None for a path that does not exist yet, which is
    # exactly the rollback a create wants: undo it by removing the file.
    restore = {path: source_bytes(path) for path in graph.pending()}
    removed = {path for path, content in graph.pending().items() if content is None}
    written = graph.save()
    verify(root, restore)
    for path in written:
        verb = "removed" if path in removed else "wrote"
        print(f"{verb} {path.relative_to(root)}", file=sys.stderr)
    return 0


DISPATCH = {
    "new": do_new,
    "set": do_set,
    "relate": do_relate,
    "unrelate": do_unrelate,
    "move": do_move,
    "delete": do_delete,
    "show": do_show,
    "list": do_list,
    "check": do_check,
}


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        reject_guarded(argv)
        root_flag, rest = split_root(argv)
        root = Path(root_flag).resolve() if root_flag else find_root(Path.cwd().resolve())
        graph = load_graph(root)
        validate_guarded(graph)
        verb, tag = resolve_type_from_argv(rest, graph)
        parser = build_parser(graph, verb, tag)
        args = parser.parse_args(argv)
        if verb in UID_FIRST_VERBS and tag is None and getattr(args, "uid", None):
            graph.node(args.uid)  # raises for an unknown UID; the prefix is history
        return DISPATCH[args.verb](graph, args, root)
    except SdocError as exc:
        print(f"sdoc: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
