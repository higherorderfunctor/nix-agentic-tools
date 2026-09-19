# cspell:ignore sdoc
"""The Bash language item set: a grammar, two queries, and no identifier rule.

Shaped exactly like `nix.py` -- a grammar path, an `element_queries` dict, a
`kind -> ELEMENT` map -- because that IS the whole per-language surface.
Nothing in `tree_sitter_extractor.py` knows this file exists.

── Two kinds ────────────────────────────────────────────────────────────────

`function`  a `function_definition`, named by its `word`. Covers both spellings
            bash accepts, `name() { ... }` and `function name { ... }`, because
            the grammar gives them the same node.

`variable`  a `variable_assignment` that is a DIRECT CHILD OF `program`, which
            is what "top level" means here. Anchoring on `(program ...)` rather
            than matching every `variable_assignment` is the difference between
            a script's handful of configuration constants and every `i=0`
            inside every loop of every function.

── There is no `id_of`, and that is the point ───────────────────────────────

Bash has no namespaces: a function's name IS its identifier, and the default
`join_name_nodes` over the single `@item.name` capture already produces it. So
this module passes no `id_of` at all rather than passing an identity function.

When this extractor runs as an INJECTION inside another language, the host
supplies the qualifying prefix (`text::sync_file`); see `Injection` in
`tree_sitter_extractor.py`. The names here stay unqualified either way, which
is what makes the same extractor serve a standalone `.sh` file and an embedded
`\'\'...\'\'` block without a flag distinguishing the two.

── The extensionless-script problem this does NOT solve ─────────────────────

An extensionless bash script is reached by NAMING IT in the glob manifest
(`SOURCE_EXTRACTORS` in `registry.py` -- NOT in `strictdoc_config.py`, which
only consumes it), never by sniffing its shebang.
That is the operator's ruling and it is a ruling about COST: content detection
means opening all ~1300 files in the tree to decide which three of them are
shell. A glob that matches nothing is a typo the manifest's own test catches;
a shebang sniffer that matches nothing is a silent 1300-file read.
"""

from __future__ import annotations

import os
from typing import Optional

from tree_sitter import Language

from .tree_sitter_extractor import TreeSitterExtractor, load_language

#: Where the compiled grammar comes from. Set on the strictdoc-grammar-extract
#: wrapper (packages/strictdoc-grammar/lib/mkExtract.nix) with `--set-default`,
#: exactly as the Nix grammar is.
BASH_PARSER_ENV = "SDOC_TS_BASH_PARSER"

#: The C entry point every tree-sitter-bash build exports.
BASH_PARSER_SYMBOL = "tree_sitter_bash"

FUNCTION_QUERY = """
(function_definition name: (word) @item.name) @item.node
"""

TOP_LEVEL_VARIABLE_QUERY = """
(program
  (variable_assignment name: (variable_name) @item.name) @item.node)
"""

#: Declaration order IS precedence, as in `nix.py`. These two can never claim
#: the same node, so the order is only convention here.
BASH_ELEMENT_QUERIES = {
    "function": FUNCTION_QUERY,
    "variable": TOP_LEVEL_VARIABLE_QUERY,
}

#: strictdoc's ELEMENT vocabulary is closed to `function` and `class`, so a
#: kind cannot be one; it travels in the item description instead. Both bash
#: kinds are `function` because neither is a type.
BASH_KIND_ELEMENTS = {
    "function": "function",
    "variable": "function",
}


def bash_parser_path(parser_path: Optional[str] = None) -> Optional[str]:
    """The explicit path, else the environment's."""
    return parser_path if parser_path else os.environ.get(BASH_PARSER_ENV)


def load_bash_language(parser_path: Optional[str] = None) -> Language:
    return load_language(
        bash_parser_path(parser_path),
        BASH_PARSER_SYMBOL,
        env_var=BASH_PARSER_ENV,
    )


def bash_extractor(
    *,
    parser_path: Optional[str] = None,
    path_root: Optional[str] = None,  # noqa: ARG001
) -> TreeSitterExtractor:
    """The Bash extractor, ready to run.

    `parser_path` defaults to `$SDOC_TS_BASH_PARSER`.

    `path_root` IS ACCEPTED AND IGNORED, deliberately. `registry.build` calls
    every language's factory with the same two keywords, and a per-language
    signature there would be a `if language == "nix"` in the one place the
    table exists to avoid. Nix needs a root because a `module` item is named
    by its file path; no bash item is.
    """
    return TreeSitterExtractor(
        language=load_bash_language(parser_path),
        element_queries=BASH_ELEMENT_QUERIES,
        comment_node_types=("comment",),
    )
