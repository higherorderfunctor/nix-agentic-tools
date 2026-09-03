# cspell:ignore attrpath attrpaths attrset attrsets sdoc mkoption
"""The Nix language item set: a grammar, three queries, and one identifier rule.

This is the whole per-language surface. Adding TypeScript means another file
shaped exactly like this one -- a grammar path, an `element_queries` dict and
an `id_of` -- and one more entry in the reader registration. Nothing in
`tree_sitter_extractor.py` or `strictdoc_reader.py` changes.

── The three kinds, most specific first ─────────────────────────────────────

`module`   a top-level lambda at least one of whose formals is named like a
           module argument (`config`, `lib`, `pkgs`, `options`, `specialArgs`,
           `inputs`). Without the `#match?` the pattern fires on ANY top-level
           lambda taking an attribute set, which in this repository is most
           `lib/` helpers.

           It is deliberately an OVER-approximation, and knowing which way it
           errs matters: `{lib}: {...}` -- a helper that takes nothing but
           `lib` -- IS reported as a module, because `lib` is in the list.
           Tightening it (say, requiring `config` or two of the names) is a
           one-line change to the alternation; nothing else depends on the
           rule. What it does exclude is a lambda whose formals are all
           project-specific names, which is the common false positive.

`option`   a binding whose value is an `mkOption` / `mkEnableOption` /
           `mkPackageOption` application, OR a binding whose own attrpath
           starts with `options.`. The three function alternatives cover
           `mkOption {}`, `lib.mkOption {}` and the curried
           `lib.mkPackageOption pkgs "x" {}`.

`binding`  any named attrpath binding. The catch-all, and the reason every
           File relation already in the corpus can be refined to an element.

Declared in that order because `TreeSitterExtractor` lets the first kind to
match a node keep it -- see its module header. Reorder these and every option
is reported as a binding.

── Two traps, both measured ─────────────────────────────────────────────────

THE NODE IS `identifier`, NOT `attr_identifier`. The grammar derivation ships
its own `queries/locals.scm` spelling `attr_identifier`, and that node type
does not exist in this build: a query using it raises "Invalid node type" at
CONSTRUCTION. `queries/tags.scm` and `queries/locals.scm` also disagree with
each other. Probe node types against the grammar; do not copy from either.

`@item.node` IS ON THE `function_expression`, NOT ON `source_code`, and the
one-token difference is a crash. A root node spans to EOF, so on a file with a
trailing newline its `end_point` is the row AFTER the last line; strictdoc then
looks that line up in `SourceFileStats.lines_info`, which only has the real
ones, and the export dies with a bare `error: 25`. `TreeSitterExtractor` also
clamps `line_end` for the same reason -- belt and braces, because the trap is
generic to every grammar.

THE ANCHOR `.` IN THE SELECT ALTERNATIVES IS LOAD-BEARING.
`(attrpath attr: (identifier) @_fn .)` pins the capture to the LAST attr of
the path, so `lib.mkOption` matches and a hypothetical `mkOption.something`
does not. Remove it and the `#match?` fires on any segment of a select path.

── The identifier convention ────────────────────────────────────────────────

A binding's id is the dotted join of every enclosing binding's attrpath:
`config.processes.scribe.exec`, `tasks."build:all".exec`.

QUOTED ATTRIBUTES KEEP THEIR QUOTES. An attrpath's text is raw source, so the
id of `tasks."generate:devenv-yaml"` is literally that, quotes included --
that is what an operator types into a File relation's `ID:` field. Any
normalization applied here must be applied identically wherever an `ID:` is
written, because a forward `ID:` that resolves to nothing is dropped SILENTLY
by strictdoc, with exit 0 and no marker.

A `module` has no attrpath, so its id is the file path instead -- relative to
`path_root` when the caller supplies one, which is how it stays typeable.

── Bash inside Nix ──────────────────────────────────────────────────────────

Half of this repository's shell lives in `''...''` strings -- every
`writeShellApplication`, every `home.activation` body -- and none of it is
reachable by a Nix query, because to tree-sitter-nix it is one opaque string.
So the Nix extractor INJECTS the bash extractor into
`indented_string_expression`, and a `sync_file() { ... }` inside a
`writeShellApplication` becomes an item like any other.

Two consequences worth knowing before writing an `ID:` against one:

* THE ID IS QUALIFIED BY THE HOST, `<enclosing attrpath>::<function name>`, so
  the function above is `text::sync_file`. The prefix is the same attrpath
  chain a `binding` item gets, computed by `make_nix_host_id_of`. Unqualified
  bash names would collide across the several shell blocks a single `.nix`
  file routinely holds.

* THE KIND IS PREFIXED, `shell-function` and `shell-variable`, so a rendered
  marker says which language the item came from. `NIX_KIND_ELEMENTS` maps both
  onto `function`, since strictdoc's ELEMENT vocabulary has nothing else.

Line and byte offsets are ABSOLUTE in the `.nix` file, and interpolations are
excluded from the bash parse; both fall out of the included-ranges mechanism
described in `tree_sitter_extractor.py`'s injections section.
"""

from __future__ import annotations

import os
from pathlib import Path
from typing import Callable, Optional

from tree_sitter import Language

from .bash import bash_extractor
from .tree_sitter_extractor import (
    ExtractorError,
    Injection,
    ItemContext,
    TreeSitterExtractor,
    load_language,
)

#: Where the compiled grammar comes from. Set on the strictdoc-grammar-extract
#: wrapper (packages/strictdoc-grammar/lib/mkExtract.nix) with `--set-default`,
#: so a developer can point it at a locally built grammar.
NIX_PARSER_ENV = "SDOC_TS_NIX_PARSER"

#: The C entry point every tree-sitter-nix build exports.
NIX_PARSER_SYMBOL = "tree_sitter_nix"

MODULE_QUERY = """
(source_code
  expression: (function_expression
    formals: (formals (formal name: (identifier) @_formal))
    (#match? @_formal
      "^(config|lib|pkgs|options|specialArgs|inputs)$")) @item.node)
"""

OPTION_QUERY = """
(binding
  attrpath: (attrpath) @item.name
  expression: (apply_expression
    function: [
      (variable_expression name: (identifier) @_fn)
      (select_expression attrpath: (attrpath attr: (identifier) @_fn .))
      (apply_expression function: [
        (variable_expression name: (identifier) @_fn)
        (select_expression attrpath: (attrpath attr: (identifier) @_fn .))])
    ]
    (#match? @_fn "^(mkOption|mkEnableOption|mkPackageOption)$"))) @item.node

(binding
  attrpath: (attrpath) @item.name
  (#match? @item.name "^options\\\\.")) @item.node
"""

BINDING_QUERY = "(binding attrpath: (attrpath) @item.name) @item.node"

#: Declaration order IS precedence. See the module header.
NIX_ELEMENT_QUERIES = {
    "module": MODULE_QUERY,
    "option": OPTION_QUERY,
    "binding": BINDING_QUERY,
}

#: strictdoc's ELEMENT vocabulary is closed to `function` and `class`, so the
#: kind cannot be one. This is the mapping onto what ELEMENT does accept; the
#: kind itself reaches the reader through the item description.
NIX_KIND_ELEMENTS = {
    "module": "class",
    "option": "function",
    "binding": "function",
    # Injected bash. See the header.
    "shell-function": "function",
    "shell-variable": "function",
}

#: The prefix injected bash kinds carry, so `function` from two grammars is
#: two kinds rather than one ambiguous one.
NIX_SHELL_KIND_PREFIX = "shell-"

#: Which Nix node holds embedded shell. `string_expression` -- the `"..."`
#: form -- is deliberately NOT a host: a one-line double-quoted string is an
#: argument, not a script, and parsing every one of them as bash buys nothing.
NIX_SHELL_HOST_NODE = "indented_string_expression"


def nix_parser_path(parser_path: Optional[str] = None) -> Optional[str]:
    """The explicit path, else the environment's."""
    return parser_path if parser_path else os.environ.get(NIX_PARSER_ENV)


def load_nix_language(parser_path: Optional[str] = None) -> Language:
    return load_language(
        nix_parser_path(parser_path),
        NIX_PARSER_SYMBOL,
        env_var=NIX_PARSER_ENV,
    )


def make_nix_id_of(
    path_root: Optional[str] = None,
) -> Callable[[ItemContext], str]:
    """The Nix identifier rule, closed over the root a module id is relative to."""

    def nix_id_of(context: ItemContext) -> str:
        if context.name_nodes:
            return _qualified_attrpath(context)
        # A module (or anything else with no name capture) is named by its file.
        return _relative_path(context.file_path, path_root)

    return nix_id_of


def _binding_attrpath_parts(node) -> list[str]:
    """Every enclosing binding's attrpath, outermost first."""
    parts: list[str] = []
    while node is not None:
        if node.type == "binding":
            attrpath = node.child_by_field_name("attrpath")
            if attrpath is not None:
                parts.insert(0, (attrpath.text or b"").decode("utf-8"))
        node = node.parent
    return parts


def _qualified_attrpath(context: ItemContext) -> str:
    """Every enclosing binding's attrpath, outermost first, joined by `.`."""
    parts = _binding_attrpath_parts(context.node)
    if not parts:
        # The capture exists but no enclosing binding does: fall back to the
        # captured text rather than inventing a name.
        return ".".join(
            (name.text or b"").decode("utf-8") for name in context.name_nodes
        )
    return ".".join(parts)


def make_nix_host_id_of(
    path_root: Optional[str] = None,
) -> Callable[[ItemContext], str]:
    """The prefix an INJECTED item's id is qualified with.

    Same attrpath chain a `binding` gets, so a shell function in
    `text = ''...''` is prefixed `text` and one in
    `config.processes.x.exec = ''...''` is prefixed with all of that. It
    cannot reuse `nix_id_of`: that one falls back to joining the `@item.name`
    captures, and an injection host has none.
    """

    def host_id_of(context: ItemContext) -> str:
        parts = _binding_attrpath_parts(context.node)
        if parts:
            return ".".join(parts)
        # A shell block that is not bound to anything -- a bare argument to a
        # function call. The file is the only honest name left.
        return _relative_path(context.file_path, path_root)

    return host_id_of


def _relative_path(file_path: Optional[str], path_root: Optional[str]) -> str:
    if not file_path:
        raise ExtractorError(
            "a Nix module item needs a file path for its identifier, and none "
            "was given; pass file_path to extract()"
        )
    path = Path(file_path)
    if path_root:
        try:
            path = path.resolve().relative_to(Path(path_root).resolve())
        except ValueError:
            pass
    return path.as_posix()


def nix_injections(
    *,
    path_root: Optional[str] = None,
    bash_parser_path: Optional[str] = None,
) -> dict:
    """Bash inside `''...''`, qualified by the enclosing attrpath."""
    return {
        NIX_SHELL_HOST_NODE: Injection(
            extractor=bash_extractor(parser_path=bash_parser_path),
            kind_prefix=NIX_SHELL_KIND_PREFIX,
            host_id_of=make_nix_host_id_of(path_root),
        )
    }


def nix_extractor(
    *,
    parser_path: Optional[str] = None,
    path_root: Optional[str] = None,
    inject_bash: bool = True,
    bash_parser_path: Optional[str] = None,
) -> TreeSitterExtractor:
    """The Nix extractor, ready to run.

    `parser_path` defaults to `$SDOC_TS_NIX_PARSER`; `path_root` is the root a
    `module` item's file-path identifier is made relative to.

    `inject_bash` defaults ON and FAILS CLOSED: with no `$SDOC_TS_BASH_PARSER`
    this raises rather than quietly returning an extractor that sees no shell.
    A caller that genuinely wants Nix items only passes `inject_bash=False`,
    which is a statement rather than an accident.
    """
    return TreeSitterExtractor(
        language=load_nix_language(parser_path),
        element_queries=NIX_ELEMENT_QUERIES,
        id_of=make_nix_id_of(path_root),
        comment_node_types=("comment",),
        injections=(
            nix_injections(
                path_root=path_root, bash_parser_path=bash_parser_path
            )
            if inject_bash
            else None
        ),
    )
