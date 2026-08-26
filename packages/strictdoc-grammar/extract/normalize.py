"""Normalize the faithful Nix surface into better Nix types, plus encoders.

Reads ``packages/strictdoc-grammar/lib/faithful.nix`` and writes
``packages/strictdoc-grammar/lib/normalized.nix``.

Every converter is a PAIR — a type rewrite (faithful type -> normalized type)
and an encoder (normalized value -> faithful value, on the way to the file).
``IS_COMPOSITE`` is ``strMatching "(True|False)"`` faithfully and ``types.bool``
normalized, so its encoder is ``b: if b then "True" else "False"``.

FAILS LOUDLY. A shape no converter recognizes is an error, never a fallback to
free text: declaring a value unconstrained is itself a NAMED converter, so "we
decided this is free text" stays distinguishable from "nobody classified this".
An upstream grammar change therefore reddens the update sweep instead of
quietly widening a type.

MEASURED, do not re-derive (see ../docs/implementation-brief.md):

* Convert a pattern to an enum ONLY when it is a single group of pure literal
  alternation. A character class, a quantifier or a nested group stays a regex
  check. Never guess an enum from a pattern that was not fully understood.
* ``ast-grep`` is the MATCHER, not a rewriter. A ``fix:`` rule emits one text
  replacement and cannot produce a type declaration *and* an encoder from one
  match, so: match, take the captures, emit both from Python. The owning
  attribute name is reachable by walking up to the enclosing ``binding`` node,
  so the field name is available alongside the pattern.
* ``ast-grep`` and its ``ast_grep_py`` bindings are both 0.45.1, tree-sitter
  based, and ship a Nix grammar — they match and capture over Nix source in
  process with nothing added.

SCAFFOLD STUB — milestone 1, SLICE-GRAMMAR-FROM-NIX. Importing works; calling
does not.
"""

from __future__ import annotations

import argparse
import sys
from typing import Sequence

import emit_nix

_TODO = "packages/strictdoc-grammar/extract/normalize.py: {0} is a scaffold stub"

DEFAULT_INPUT = "packages/strictdoc-grammar/lib/faithful.nix"
DEFAULT_OUTPUT = "packages/strictdoc-grammar/lib/normalized.nix"


class UnrecognizedShape(Exception):
    """Raised when no named converter claims a faithful node.

    This is the fail-closed condition, and it is deliberately an exception and
    not a warning: an unclassified shape must stop the sweep.
    """


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="strictdoc-grammar-normalize",
        description="Rewrite the faithful .sgra surface into normalized types plus encoders.",
    )
    parser.add_argument(
        "--input",
        default=DEFAULT_INPUT,
        help="path of the faithful surface to read (default: %(default)s)",
    )
    parser.add_argument(
        "--output",
        default=DEFAULT_OUTPUT,
        help="path of the normalized surface to write (default: %(default)s)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="regenerate and diff instead of writing; non-zero exit on drift",
    )
    return parser


def match_faithful(source: str) -> list:
    """Match the faithful surface's Nix source with ast-grep, keeping captures."""
    raise NotImplementedError(_TODO.format("match_faithful"))


def convert(node: object) -> tuple:
    """Apply the first named converter that claims ``node``.

    Returns ``(type_rewrite, encoder)``. Raises ``UnrecognizedShape`` when none
    claims it.
    """
    raise NotImplementedError(_TODO.format("convert"))


def normalize() -> dict:
    """Produce the normalized surface as plain data, ready for ``emit_nix``."""
    raise NotImplementedError(_TODO.format("normalize"))


def main(argv: Sequence[str] | None = None) -> int:
    build_parser().parse_args(argv)
    raise NotImplementedError(_TODO.format("main"))


if __name__ == "__main__":
    sys.exit(main())
