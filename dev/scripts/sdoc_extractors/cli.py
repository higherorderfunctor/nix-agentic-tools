#!/usr/bin/env python3
# cspell:ignore sdoc attrpath
"""sdoc-extract -- list the language items a file offers, and check one by id.

    strictdoc-grammar-extract dev/scripts/sdoc_extractors/__main__.py FILE...
    python3 -m sdoc_extractors --id 'config.processes.scribe' FILE

WHY THIS EXISTS AT ALL. strictdoc drops a forward `ID:` that resolves to
nothing SILENTLY -- exit 0, no marker, and the relation simply does not appear
on either page. A right id and a wrong id look identical from the outside, so
before writing `ELEMENT`/`ID` into a File relation, resolve the id here:
`--id` exits 1 and says "no such item" when nothing matches, which is the loud
check strictdoc does not give you.

`--kind` narrows the listing; `--json` is for machines. Everything is printed
in source order, and identifiers are printed EXACTLY as they must be typed --
quoted Nix attributes keep their quotes.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .nix import NIX_KIND_ELEMENTS, nix_extractor
from .tree_sitter_extractor import ExtractorError, TreeSitterExtractor

#: Language name -> (extractor factory, kind -> ELEMENT map). One row per
#: language; a new grammar adds a row and changes nothing else.
LANGUAGES = {
    "nix": (nix_extractor, NIX_KIND_ELEMENTS),
}


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="sdoc-extract",
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("files", nargs="+", type=Path)
    parser.add_argument(
        "--language",
        default="nix",
        choices=sorted(LANGUAGES),
        help="which language item set to apply (default: nix)",
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
        help="repository root a file-path identifier is made relative to",
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


def _extractor(args) -> TreeSitterExtractor:
    factory, _elements = LANGUAGES[args.language]
    return factory(parser_path=args.parser, path_root=args.root)


def main(argv: list | None = None) -> int:
    args = build_parser().parse_args(argv)
    _factory, kind_elements = LANGUAGES[args.language]

    try:
        extractor = _extractor(args)
    except ExtractorError as error:
        print(f"sdoc-extract: {error}", file=sys.stderr)
        return 2

    wanted = set(args.kind) if args.kind else None
    records = []
    for path in args.files:
        try:
            source = path.read_bytes()
        except OSError as error:
            print(f"sdoc-extract: {error}", file=sys.stderr)
            return 2
        try:
            items = extractor.extract(source, str(path))
        except ExtractorError as error:
            print(f"sdoc-extract: {path}: {error}", file=sys.stderr)
            return 2
        for item in items:
            if wanted is not None and item.kind not in wanted:
                continue
            records.append(
                {
                    "file": path.as_posix(),
                    "kind": item.kind,
                    "id": item.identifier,
                    "element": kind_elements.get(item.kind, "function"),
                    "description": item.description,
                    "line_begin": item.line_begin,
                    "line_end": item.line_end,
                    "has_comment": item.has_comment,
                }
            )

    if args.identifier is not None:
        matches = [
            record
            for record in records
            if record["id"] == args.identifier
        ]
        if not matches:
            print(
                f"sdoc-extract: no such item: {args.identifier!r} is offered "
                f"by none of {', '.join(p.as_posix() for p in args.files)}. "
                "A File relation naming it would be dropped SILENTLY by "
                "strictdoc.",
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
