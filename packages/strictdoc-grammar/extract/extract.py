"""Faithful extraction of StrictDoc's ``.sgra`` grammar into a Nix surface.

Writes ``packages/strictdoc-grammar/lib/faithful.nix``. Runs at generation time,
outside Nix; Nix never parses StrictDoc during evaluation.

MEASURED, do not re-derive (see ../docs/implementation-brief.md):

* StrictDoc assembles its own grammar into a plain string, byte-identical
  between 0.28.2 and 0.28.3::

      from textx import metamodel_from_str
      from strictdoc.backend.sdoc.grammar.grammar_builder import (
          SDocGrammarBuilder as B,
      )

      mm = metamodel_from_str(B.create_grammar_grammar())

* BOTH access paths are needed. The metamodel (``mm[rule]._tx_attrs``,
  ``_tx_inh_by``, ``_tx_type``) yields the skeleton; walking from
  ``DocumentGrammarWrapper`` reaches 25 of 43 rules and the rest are
  document-side. The parser tree (``mm[rule]._tx_peg_rule``, walked as arpeggio
  ``Optional`` / ``RegExMatch`` / ``StrMatch`` / ``OrderedChoice`` nodes) is
  REQUIRED on top, because the metamodel reports every attribute as ``mult=1``
  regardless of optionality and flattens value vocabularies to ``STRING``.
* Literal sets arrive in TWO shapes and both must be handled: named rules
  (``BooleanChoice`` is an ``OrderedChoice`` of ``StrMatch`` children) and
  inline regex alternations (``IS_COMPOSITE`` is ``/(True|False)/``).

Faithful means faithful: this module classifies nothing. A value constrained by
a regex comes out as a string carrying that regex. Turning a pure literal
alternation into an enum is ``normalize.py``'s job.

SCAFFOLD STUB — milestone 1, SLICE-GRAMMAR-FROM-NIX. Importing works; calling
does not.
"""

from __future__ import annotations

import argparse
import sys
from typing import Sequence

import emit_nix

_TODO = "packages/strictdoc-grammar/extract/extract.py: {0} is a scaffold stub"

DEFAULT_OUTPUT = "packages/strictdoc-grammar/lib/faithful.nix"


def build_parser() -> argparse.ArgumentParser:
    """Command line: where to write, and whether to diff instead of write."""
    parser = argparse.ArgumentParser(
        prog="strictdoc-grammar-extract",
        description="Extract StrictDoc's .sgra grammar into a faithful Nix surface.",
    )
    parser.add_argument(
        "--output",
        default=DEFAULT_OUTPUT,
        help="path of the faithful surface to write (default: %(default)s)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="regenerate and diff instead of writing; non-zero exit on drift",
    )
    return parser


def load_metamodel() -> object:
    """Build the textx metamodel of the ``.sgra`` grammar."""
    raise NotImplementedError(_TODO.format("load_metamodel"))


def walk_rules(metamodel: object) -> dict:
    """Walk from ``DocumentGrammarWrapper`` and collect the reachable rules."""
    raise NotImplementedError(_TODO.format("walk_rules"))


def extract() -> dict:
    """Produce the faithful surface as plain data, ready for ``emit_nix``."""
    raise NotImplementedError(_TODO.format("extract"))


def main(argv: Sequence[str] | None = None) -> int:
    build_parser().parse_args(argv)
    raise NotImplementedError(_TODO.format("main"))


if __name__ == "__main__":
    sys.exit(main())
