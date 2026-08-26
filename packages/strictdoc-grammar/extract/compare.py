# cspell:ignore lineterm sgra textx tofile
"""Compare two ``.sgra`` files by the MODEL StrictDoc builds from each.

Semantic equality is this milestone's correctness gate (acceptance item 4);
byte-identity is only the regression gate. A rendered file that differs in
whitespace or key order but parses to the same ``DocumentGrammar`` is correct —
and one that matches byte for byte but parses to something else would not be.

Reads both files through ``SDocGrammarReader.read``, which is the real reader:
the same metamodel, the same ``classes=GRAMMAR_MODELS`` registration and the
same ``use_regexp_group=True`` the rest of StrictDoc parses grammars with.
Building a bare metamodel here instead would compare something StrictDoc never
constructs.

The comparison walks the two object graphs generically rather than naming
fields. Naming them would be a hand-written list of exactly the things this
milestone generates, so it would agree with itself by construction; a generic
walk notices a field nobody thought to compare. ``parent`` back-references and
``_``-prefixed attributes are skipped — the first makes the graph cyclic, the
second is textx bookkeeping that ``drop_textx_meta`` has already half-removed.

Usage::

    strictdoc-grammar-extract packages/strictdoc-grammar/extract/compare.py \\
      docs/sdoc/grammar.sgra /tmp/emitted.sgra
"""

from __future__ import annotations

import argparse
import sys
from typing import Any

from strictdoc.backend.sdoc.grammar_reader import SDocGrammarReader

# Attributes that are structure rather than content. `parent` points back up
# and makes the walk cyclic; the `ng_*` source-location data records WHERE a
# node was written, which is exactly what two spellings of one grammar are
# allowed to differ in.
#
# `mid` is the load-bearing one. StrictDoc mints a fresh random MID for every
# node on every parse unless the source declares one, and a `.sgra` has no
# syntax to declare one — so two reads of the SAME BYTES already disagree on
# every `mid` in the file. Comparing them would make the gate always fail;
# keeping them is not stricter, it is broken.
SKIP = frozenset(
    {
        "mid",
        "ng_byte_start",
        "ng_byte_end",
        "ng_col_end",
        "ng_col_start",
        "ng_line_end",
        "ng_line_start",
        "parent",
    }
)


def canonical(value: Any, depth: int = 0) -> Any:
    """A hashable, order-preserving dump of one model node."""
    if depth > 64:
        raise RecursionError("model graph deeper than 64 levels")
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    if isinstance(value, (list, tuple)):
        return [canonical(item, depth + 1) for item in value]
    if isinstance(value, dict):
        # Insertion order is meaningful in StrictDoc's derived maps
        # (`fields_order_by_type` and friends), so it is preserved rather
        # than sorted.
        return {
            str(key): canonical(item, depth + 1) for key, item in value.items()
        }
    if hasattr(value, "__dict__"):
        return {
            "@": type(value).__name__,
            **{
                name: canonical(item, depth + 1)
                for name, item in vars(value).items()
                if name not in SKIP and not name.startswith("_")
            },
        }
    return repr(value)


def model_of(path: str) -> Any:
    with open(path, encoding="utf-8") as handle:
        return SDocGrammarReader.read(handle.read(), file_path=path)


def render(value: Any, indent: int = 0) -> list[str]:
    """A line-per-leaf rendering, so a mismatch can be diffed by eye."""
    pad = "  " * indent
    if isinstance(value, dict):
        lines = []
        for key, item in value.items():
            if isinstance(item, (dict, list)):
                lines.append(f"{pad}{key}:")
                lines.extend(render(item, indent + 1))
            else:
                lines.append(f"{pad}{key}: {item!r}")
        return lines
    if isinstance(value, list):
        lines = []
        for position, item in enumerate(value):
            if isinstance(item, (dict, list)):
                lines.append(f"{pad}[{position}]")
                lines.extend(render(item, indent + 1))
            else:
                lines.append(f"{pad}[{position}] {item!r}")
        return lines
    return [f"{pad}{value!r}"]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("left", help="a .sgra file")
    parser.add_argument("right", help="the .sgra file to compare it against")
    args = parser.parse_args(argv)

    left = canonical(model_of(args.left))
    right = canonical(model_of(args.right))

    if left == right:
        print(f"models equal: {args.left} == {args.right}")
        return 0

    import difflib

    print(f"MODELS DIFFER: {args.left} != {args.right}", file=sys.stderr)
    diff = difflib.unified_diff(
        render(left),
        render(right),
        fromfile=args.left,
        tofile=args.right,
        lineterm="",
    )
    for line in diff:
        print(line, file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
