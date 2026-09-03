#!/usr/bin/env python3
# cspell:ignore sdoc attrpath
"""List the language items a file offers, and check one by id.

    strictdoc-grammar-extract dev/scripts/sdoc_extractors/__main__.py FILE...
    python3 -m sdoc_extractors --id 'config.processes.scribe' FILE

WHY THIS EXISTS AT ALL. strictdoc drops a forward `ID:` that resolves to
nothing SILENTLY -- exit 0, no marker, and the relation simply does not appear
on either page. A right id and a wrong id look identical from the outside, so
before writing `ELEMENT`/`ID` into a File relation, resolve the id here:
`--id` exits 1 and says "no such item" when nothing matches, which is the loud
check strictdoc does not give you.

THIS TOOL MUST ANSWER WHAT THE WRITE PATH ANSWERS, so it routes every file
through `registry.SOURCE_EXTRACTORS` -- the same table `strictdoc_config.py`
routes strictdoc's reader with and the same one `sdoc_model.check_file_item`
and `element-check.py` validate against. It used to carry its OWN table,
`LANGUAGES = {"nix": ...}`, with `--language` defaulting to `nix`, and that
divergence was worse than having no tool: a bash script was PARSED WITH THE
NIX GRAMMAR, so `--id diff_quiet lib/validate-at-stop.sh` answered "no such
item ... would be dropped SILENTLY by strictdoc" for an id the write path
accepts and the bash extractor reports at lines 34-45, and a bare listing of
that file printed one FABRICATED item and exited 0. A checker that is
confidently wrong sends you to change correct input.

An uncovered path is REFUSED (exit 1) rather than parsed with a guess: "no
glob covers this" and "covered, and this id is not in it" are different
answers and the operator acts on them differently.

`--language` remains as an explicit OVERRIDE for probing a file the table does
not route (a fixture, a candidate row). It has no default, so it can never
silently misapply a grammar the way it used to.

`--kind` narrows the listing; `--json` is for machines. Everything is printed
in source order, and identifiers are printed EXACTLY as they must be typed --
quoted Nix attributes keep their quotes.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Optional

from . import registry
from .tree_sitter_extractor import ExtractorError

def _languages() -> dict:
    """language name -> the first row of the table declaring it.

    Only `--language` reads this; routing reads the globs. It is DERIVED from
    the table rather than written down, so a new row cannot be reachable by
    path and unreachable by name (or, as it was, the reverse).
    """
    by_name: dict = {}
    for spec in registry.SOURCE_EXTRACTORS.values():
        by_name.setdefault(spec.language, spec)
    return by_name


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        # The USAGE line is an instruction, so it spells the invocation that
        # actually works. `prog="sdoc-extract"` printed a command that does
        # not exist -- there is no such binary on PATH; this tool is a script
        # strictdoc's venv runner executes. The `sdoc-extract:` prefix on the
        # messages below stays, as a label rather than a thing to type.
        prog=registry.LIST_COMMAND,
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("files", nargs="+", type=Path)
    parser.add_argument(
        "--language",
        default=None,
        choices=sorted(_languages()),
        help="force this language instead of routing the path through "
        "SOURCE_EXTRACTORS (default: route)",
    )
    parser.add_argument(
        "--parser",
        default=None,
        help="path to the compiled grammar's ./parser "
        "(default: the language's environment variable)",
    )
    parser.add_argument(
        "--root",
        default=None,
        help="repository root a file-path identifier is made relative to, "
        "and the root the routing globs are matched against "
        "(default: the nearest ancestor of the working directory holding "
        "strictdoc_config.py)",
    )
    parser.add_argument(
        "--kind",
        action="append",
        default=None,
        help="only list this kind; repeatable",
    )
    parser.add_argument(
        "--id",
        dest="identifier",
        default=None,
        help="resolve this identifier and exit 1 if no file offers it",
    )
    parser.add_argument(
        "--json", action="store_true", help="emit records as JSON"
    )
    return parser


def default_root() -> Optional[Path]:
    """The repository root, found the way every other scribe program finds it.

    THE GLOBS ARE REPOSITORY-RELATIVE, so without a root an absolute path is
    matched as `/home/.../flake.nix` and `**/*.nix` cannot claim it -- `**`
    matches whole segments and a leading `/` makes the first one empty, so
    every file would report as covered by nothing. Walking up for
    `strictdoc_config.py` is the same marker mkScribe.nix's wrapper and
    sdoc_cli.py use, so the tool routes a path exactly as the writer does.
    """
    for directory in (Path.cwd(), *Path.cwd().parents):
        if (directory / "strictdoc_config.py").is_file():
            return directory
    return None


def _items_and_elements(path: Path, args):
    """(items, kind -> ELEMENT) for one file, or a refusal string."""
    if args.language is not None:
        spec = _languages()[args.language]
        extractor = registry.build(
            spec, path_root=args.root, parser_path=args.parser
        )
        return extractor.extract(path.read_bytes(), str(path)), spec.kind_elements

    spec = registry.extractor_for(path, args.root)
    if spec is None:
        raise registry.UnsupportedPath(
            f"no source extractor covers "
            f"{registry.relative_to(path, args.root)!r} "
            f"(configured globs: {registry.describe_globs()}). "
            "Nothing parses it, so a File relation naming an ID inside it "
            "can never resolve. Add a row to SOURCE_EXTRACTORS, or pass "
            "--language to probe it anyway."
        )
    items = registry.items_of(
        path, path_root=args.root, parser_path=args.parser
    )
    return items, spec.kind_elements


def main(argv: list | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.root is None:
        root = default_root()
        args.root = str(root) if root is not None else None

    wanted = set(args.kind) if args.kind else None
    records = []
    # Kept per file so an `--id` miss can be explained against the ONE file
    # that was supposed to offer it, with its nearest ids.
    items_by_path: dict = {}
    for path in args.files:
        try:
            items, kind_elements = _items_and_elements(path, args)
        except registry.UnsupportedPath as error:
            print(f"sdoc-extract: {error}", file=sys.stderr)
            return 1
        except ExtractorError as error:
            print(f"sdoc-extract: {path}: {error}", file=sys.stderr)
            return 2
        except OSError as error:
            print(f"sdoc-extract: {error}", file=sys.stderr)
            return 2
        items_by_path[path] = items
        for item in items:
            if wanted is not None and item.kind not in wanted:
                continue
            records.append(
                {
                    "file": path.as_posix(),
                    "kind": item.kind,
                    "id": item.display_name,
                    "element": kind_elements.get(item.kind, "function"),
                    "description": item.description,
                    "line_begin": item.line_begin,
                    "line_end": item.line_end,
                    "has_comment": item.has_comment,
                }
            )

    if args.identifier is not None:
        matches = [
            record for record in records if record["id"] == args.identifier
        ]
        if not matches:
            print(
                f"sdoc-extract: {_explain(args, items_by_path)}",
                file=sys.stderr,
            )
            return 1
        records = matches

    if args.json:
        json.dump(records, sys.stdout, indent=2, sort_keys=True)
        sys.stdout.write("\n")
    else:
        for record in records:
            print(
                f"{record['file']}\t{record['kind']}\t"
                f"{record['element']}\t{record['id']}\t"
                f"{record['line_begin']}-{record['line_end']}"
            )
    return 0


def _explain(args, items_by_path: dict) -> str:
    """The `--id` miss, worded exactly as the write path words it.

    One file is the normal case and gets `registry.explain_missing_id`, which
    is the same sentence `sdoc_model.check_file_item` refuses with -- the tool
    and the writer must not disagree about what a file offers.
    """
    if len(items_by_path) == 1:
        (path, items), = items_by_path.items()
        return registry.explain_missing_id(
            path, args.identifier, items, path_root=args.root
        )
    files = ", ".join(path.as_posix() for path in items_by_path)
    return (
        f"no such item: {args.identifier!r} is offered by none of {files}. "
        "A File relation naming it would be dropped SILENTLY by strictdoc."
    )
