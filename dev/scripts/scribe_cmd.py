#!/usr/bin/env python3
# cspell:ignore sdoc sgra unrelate argparse
"""The `scribe` command: turn a command line into one typed operation
(WORK-SCRIBE-CLIENT, docs/plans/scribe-daemon/).

Stdlib only. No strictdoc import, no corpus load, no graph.

WHERE THE FLAGS COME FROM
-------------------------
The option surface is derived from the grammar, the same as it always was --
one flag per declared field, each choice list read off that field, the
relation roles off the element. What changed is that it is read from the
grammar FILE rather than from a loaded project, so building it costs no
corpus and needs no daemon. `scribe new DECISION --help` and
`scribe new NARRATIVE --help` still print different surfaces, and still get
them from the one place the daemon also resolves.

WHAT THE DAEMON GETS
--------------------
An operation, never an argument list:

    scribe set MECH-X --depth sketch
      -> {"op": "set", "uid": "MECH-X", "fields": {"DEPTH": "sketch"}}

`@file` and `-` are resolved HERE, against the caller's working directory and
the caller's stdin, which the daemon has neither of.

Some refusals therefore move: whether a node's type declares `--depth` is
answered by the daemon, because the type comes from the index and a UID
prefix is a birth-name, not a type. The refusal is the same, the message is
better, and it arrives from a different place.

THERE IS NO FALLBACK
--------------------
No daemon means exit non-zero naming the socket and the command that starts
one (DEC-SCRIBE-DAEMON-NO-FALLBACK).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from scribe_client import ClientError, call_for_root  # noqa: E402
from scribe_grammar import parse_sgra  # noqa: E402
from scribe_paths import RootError, resolve_root  # noqa: E402
from scribe_protocol import WRITES  # noqa: E402

# MECH-RUNTIME-WRITE-GUARD: no flag is generated for either, and naming one
# is refused before anything else happens.
GUARDED = ("AUTHORED_BY", "PARENT_FP")


def read_value(raw: str) -> str:
    """`@path` reads a file, `-` reads stdin, anything else is itself.

    Resolved here rather than in the daemon: these are relative to the
    CALLER's working directory and the CALLER's stdin.
    """
    if raw == "-":
        return sys.stdin.read().rstrip("\n")
    if raw.startswith("@"):
        path = Path(raw[1:])
        if not path.is_file():
            raise SystemExit(f"scribe: {path} is not a readable file")
        return path.read_text(encoding="utf8").rstrip("\n")
    return raw


def flag_for(field_name: str) -> str:
    return "--" + field_name.lower().replace("_", "-")


def attr_for(field_name: str) -> str:
    return "field_" + field_name


def add_field_flags(parser, element, *, required: bool) -> None:
    for field in element["fields"]:
        name = field["name"]
        if name in GUARDED:
            continue
        parser.add_argument(
            flag_for(name),
            dest=attr_for(name),
            metavar="VALUE",
            required=required and field["required"],
            choices=field["options"] or None,
            help=f"{name}" + (f" ({'|'.join(field['options'])})" if field["options"] else ""),
        )


def build_parser(grammar: dict, command: str | None, tag: str | None):
    parser = argparse.ArgumentParser(
        prog="scribe",
        description="Write and read this repository's design canon, through the scribe daemon.",
    )
    parser.add_argument("--root", help="the workspace (default: $SCRIBE_ROOT, then cwd)")
    subparsers = parser.add_subparsers(dest="command", required=True)

    new_parser = subparsers.add_parser("new", help="create a node in a file of its own")
    types = new_parser.add_subparsers(dest="node_type", required=True)
    for candidate in sorted(grammar):
        one = types.add_parser(candidate, help=f"create a {candidate}")
        add_field_flags(one, grammar[candidate], required=True)
        one.add_argument("--path", required=True, metavar="FILE-OR-DIR")
        roles = sorted({r["role"] or "File" for r in grammar[candidate]["roles"]})
        one.add_argument(
            "--relate", action="append", default=[], metavar="ROLE=TARGET",
            help="one of: " + ", ".join(roles),
        )

    set_parser = subparsers.add_parser("set", help="set or unset fields on a node")
    set_parser.add_argument("uid")
    if command == "set" and tag and tag in grammar:
        add_field_flags(set_parser, grammar[tag], required=False)
        optional = [
            f["name"] for f in grammar[tag]["fields"]
            if not f["required"] and f["name"] not in GUARDED
        ]
        set_parser.add_argument("--unset", action="append", default=[], choices=optional)
    else:
        # No type known yet: accept every field any type declares, and let the
        # daemon refuse the ones this node's type does not have.
        seen = {}
        for element in grammar.values():
            for field in element["fields"]:
                seen.setdefault(field["name"], field)
        add_field_flags(set_parser, {"fields": list(seen.values())}, required=False)
        set_parser.add_argument("--unset", action="append", default=[])

    for verb in ("relate", "unrelate"):
        one = subparsers.add_parser(verb, help=f"{verb} a node")
        one.add_argument("uid")
        one.add_argument("--role", required=True)
        one.add_argument("--target", required=True)
        # A File relation may name one ITEM in the file rather than the whole
        # of it. These three slots are strictdoc's FileEntry, not the .sgra
        # grammar -- which declares a File relation by TYPE alone -- so there
        # is nothing here to derive them from and no `choices` to attach. The
        # vocabulary and every refusal live in sdoc_model on the daemon side,
        # the same way a field illegal for a node's type is refused there:
        # this client states the surface, the daemon holds the rule.
        one.add_argument(
            "--element",
            metavar="function|class",
            help="with --role File: the relation names an item in the file. Needs --id",
        )
        one.add_argument(
            "--id",
            dest="element_id",
            metavar="QUALIFIED-NAME",
            help='which item, as the reader names it (quotes included: tasks."build:all")',
        )
        one.add_argument(
            "--line-range",
            metavar="BEGIN-END",
            help="with --role File: the lines named. Not combinable with --element/--id",
        )

    move_parser = subparsers.add_parser("move", help="move a node's file")
    move_parser.add_argument("uid")
    move_parser.add_argument("--path", required=True)

    subparsers.add_parser("delete", help="delete a node").add_argument("uid")
    subparsers.add_parser("check", help="validate every node, relation and File path")
    subparsers.add_parser("show", help="print a node with its relations resolved").add_argument("uid")

    list_parser = subparsers.add_parser("list", help="list nodes, filtered")
    list_parser.add_argument("--type", dest="node_type")
    list_parser.add_argument("--depth")
    list_parser.add_argument("--status")

    # READ-ONLY, AND IT NEVER REACHES THE DAEMON. What a state field's values
    # MEAN is a property of the grammar plus dev/scripts/sdoc_semantics/, both
    # of which are files; the corpus has no say in it. So this answers with
    # the daemon down, which is deliberate -- the first thing an operator
    # wants when the graph will not load is the vocabulary it refused.
    semantics_parser = subparsers.add_parser(
        "semantics",
        help="the lifecycle a state field claims, and the rules nobody has settled",
    )
    semantics_parser.add_argument(
        "selector", nargs="?", metavar="FIELD|TYPE",
        help="one state field (DEPTH) or one node type (DECISION); default all",
    )
    output = semantics_parser.add_mutually_exclusive_group()
    output.add_argument("--json", action="store_true", help="the sdoc-semantics/1 payload")
    output.add_argument("--mermaid", action="store_true", help="stateDiagram-v2 per machine")

    def leaves(candidate):
        nested = [
            action
            for action in candidate._actions
            if isinstance(action, argparse._SubParsersAction)
        ]
        if not nested:
            return [candidate]
        return [
            leaf
            for action in nested
            for child in action.choices.values()
            for leaf in leaves(child)
        ]

    for name in WRITES:
        for write_parser in leaves(subparsers.choices[name]):
            write_parser.add_argument(
                "--dry-run",
                action="store_true",
                help="validate and print what would change without writing",
            )
    return parser


def run_semantics(args, grammar: dict) -> int:
    """`scribe semantics` -- ONE renderer, shared with `python -m sdoc_semantics`.

    Imported HERE rather than at module import so `transitions` stays a cost of
    this subcommand alone. It is delivered on the two interpreters that matter
    (packages/strictdoc-grammar/lib/mkExtract.nix and devenv.nix's grammarPython)
    and on nothing else. A missing engine must cost this one subcommand, never
    `scribe set`.
    """
    try:
        from sdoc_semantics import cli as semantics_cli
    except ImportError as exc:
        print(
            f"scribe: the semantics engine is unavailable ({exc}). It needs "
            f"`transitions` on this interpreter; run under the dev shell or "
            f"strictdoc-grammar-extract.",
            file=sys.stderr,
        )
        return 1
    data = semantics_cli.build_payload(grammar)
    try:
        sys.stdout.write(
            semantics_cli.emit(
                data, args.selector, as_json=args.json, as_mermaid=args.mermaid
            )
        )
    except SystemExit as exc:
        if isinstance(exc.code, str):
            print(f"scribe: {exc.code}", file=sys.stderr)
            return 1
        raise
    return 0


def reject_guarded(argv: list[str]) -> None:
    for token in argv:
        bare = token.split("=", 1)[0].lstrip("-").replace("-", "_").upper()
        if bare in GUARDED and token.startswith("-"):
            raise SystemExit(
                f"scribe: {bare} is the operator's to set, not the writer's; "
                f"there is deliberately no flag for it"
            )


def peek(argv: list[str]) -> tuple[str | None, str | None]:
    """The command, and the node type when it is spelled out (`new TYPE`)."""
    positional = [a for a in argv if not a.startswith("-")]
    command = positional[0] if positional else None
    tag = positional[1] if command == "new" and len(positional) > 1 else None
    return command, tag


def fields_from(args, grammar: dict) -> dict:
    out = {}
    for element in grammar.values():
        for field in element["fields"]:
            raw = getattr(args, attr_for(field["name"]), None)
            if raw is not None:
                out[field["name"]] = read_value(raw)
    return out


def operation(args, grammar: dict) -> dict:
    command = args.command
    if command == "show":
        payload = {"op": "show", "uid": args.uid}
    elif command == "list":
        payload = {
            "op": "list",
            "type": args.node_type,
            "depth": args.depth,
            "status": args.status,
        }
    elif command == "check":
        payload = {"op": "check"}
    elif command == "new":
        relations = []
        for spec in args.relate:
            role, separator, target = spec.partition("=")
            if not separator:
                raise SystemExit(f"scribe: --relate wants ROLE=TARGET, got {spec!r}")
            relations.append({"role": role, "target": target})
        fields = fields_from(args, grammar)
        payload = {
            "op": "new", "type": args.node_type, "uid": fields.pop("UID", None),
            "fields": fields, "relations": relations, "path": args.path,
        }
    elif command == "set":
        payload = {
            "op": "set", "uid": args.uid,
            "fields": fields_from(args, grammar), "unset": args.unset,
        }
    elif command in ("relate", "unrelate"):
        payload = {
            "op": command,
            "uid": args.uid,
            "role": args.role,
            "target": args.target,
            "element": args.element,
            "id": args.element_id,
            "line_range": args.line_range,
        }
    elif command == "move":
        payload = {"op": "move", "uid": args.uid, "path": args.path}
    else:
        payload = {"op": "delete", "uid": args.uid}
    if command in WRITES:
        payload["dry_run"] = args.dry_run
    return payload


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        reject_guarded(argv)
        root = resolve_root(next(
            (argv[i + 1] for i, a in enumerate(argv) if a == "--root" and i + 1 < len(argv)),
            next((a.split("=", 1)[1] for a in argv if a.startswith("--root=")), None),
        ))
        grammar = parse_sgra(root / "docs" / "sdoc" / "grammar.sgra")
        command, tag = peek(argv)
        args = build_parser(grammar, command, tag).parse_args(argv)
        if args.command == "semantics":
            # SHORT-CIRCUIT BEFORE ANY RPC. Everything this needs is already
            # in hand: the grammar was parsed client-side a few lines up.
            return run_semantics(args, grammar)
        payload = operation(args, grammar)
    except RootError as exc:
        print(f"scribe: {exc}", file=sys.stderr)
        return 1
    except SystemExit as exc:
        if isinstance(exc.code, str):  # our own refusals carry text
            print(exc.code, file=sys.stderr)
            return 1
        return exc.code if isinstance(exc.code, int) else 1

    try:
        result = call_for_root(root, "scribe.apply", payload)
    except ClientError as exc:
        print(f"scribe: {exc}", file=sys.stderr)
        return 1

    if text := result.get("text"):
        sys.stdout.write(text if text.endswith("\n") else text + "\n")
    for written in result.get("written", []):
        print(f"wrote {written}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
