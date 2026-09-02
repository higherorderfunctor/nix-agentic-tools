# cspell:ignore attrpath attrset sdoc
"""The language-agnostic half of the source extractor: tree-sitter in, plain
records out.

NOTHING IN THIS MODULE IMPORTS STRICTDOC, and that is the point. The extractor
is usable from any interpreter that has `tree_sitter` -- a check, a one-off
script, a future `bd` importer -- and `strictdoc_reader.py` is the only file
that knows strictdoc exists. Keeping the split means a broken strictdoc pin
cannot stop the extractor from being run to find out what it sees.

── The shape a new language has to fill in ──────────────────────────────────

    TreeSitterExtractor(
        language=<tree_sitter.Language>,
        element_queries={"module": Q_MODULE, "option": Q_OPTION, ...},
        id_of=<callable ItemContext -> str>,
    )

`element_queries` maps a KIND WORD to a tree-sitter query. Each query must
capture `@item.node` -- the node whose byte range and line span become the
item -- and may capture `@item.name`, the node(s) whose text the default
`id_of` joins into an identifier. The dict KEY is the kind; nothing else
carries it. See `strictdoc_reader.py` for why the kind cannot be an ELEMENT
value and has to travel in the description instead.

`id_of` is the ONE per-language callable. Nix joins every enclosing binding's
attrpath; TypeScript would unwrap `export_statement` and read the `name` field.
Everything else -- parsing, comment attachment, dedup, ordering -- is shared.

── Two ordering rules that are load-bearing ─────────────────────────────────

1. `element_queries` is iterated in INSERTION ORDER and the first kind to
   claim a node wins. An `option` binding is also a `binding`, so the specific
   query must be declared before the catch-all or every option is reported as
   a binding.

2. Queries are compiled in `__init__`, not on first parse. A malformed query
   raises at construction naming the kind, which is what turns the
   tree-sitter node-name traps (see `nix.py`) into an immediate, legible
   failure instead of a silent empty capture set much later.
"""

from __future__ import annotations

import ctypes
import os
import warnings
from dataclasses import dataclass
from typing import Callable, Iterable, Mapping, NamedTuple, Optional, Sequence

from tree_sitter import Language, Node, Parser, Query, QueryCursor

#: The capture every element query must carry: the node that becomes the item.
ITEM_CAPTURE = "item.node"

#: The optional capture whose text the default `id_of` joins into an identifier.
NAME_CAPTURE = "item.name"


class ExtractorError(Exception):
    """A query, a grammar or an identifier could not be produced."""


class ItemContext(NamedTuple):
    """Everything `id_of` is given about one captured item."""

    kind: str
    node: Node
    name_nodes: tuple[Node, ...]
    source: bytes
    file_path: Optional[str]


@dataclass(frozen=True)
class ExtractedItem:
    """One extracted language item, in plain data.

    Line numbers are 1-BASED. `line_begin` EXCLUDES leading comment lines and
    `line_begin_with_comment` includes them; strictdoc wants both, at different
    call sites, and conflating them misplaces either the highlight or the
    marker (see `strictdoc_reader.py`).
    """

    kind: str
    identifier: str
    line_begin: int
    line_end: int
    byte_begin: int
    byte_end: int
    comment_text: Optional[str] = None
    comment_line_begin: Optional[int] = None
    comment_byte_begin: Optional[int] = None
    comment_byte_end: Optional[int] = None

    @property
    def display_name(self) -> str:
        """What a user writes in an `ID:` field to reach this item."""
        return self.identifier

    @property
    def description(self) -> str:
        """The kind-carrying label. THE ONLY channel the kind travels on."""
        return f"{self.kind} {self.identifier}"

    @property
    def has_comment(self) -> bool:
        return self.comment_text is not None

    @property
    def line_begin_with_comment(self) -> int:
        if self.comment_line_begin is None:
            return self.line_begin
        return self.comment_line_begin


@dataclass(frozen=True)
class FileComment:
    """A comment at the very top of a file, which documents the file itself."""

    text: str
    line_begin: int
    byte_begin: int
    byte_end: int


def load_language(
    parser_path: Optional[str],
    symbol: str,
    *,
    env_var: Optional[str] = None,
) -> Language:
    """Load a tree-sitter grammar from a compiled `parser` shared object.

    THE CTYPES ROUTE IS DELIBERATE. nixpkgs also ships
    `python3Packages.tree-sitter-grammars.*`, whose python binding drags in
    pydantic, email_validator, dnspython and idna -- none of which strictdoc's
    own venv carries, and that venv is the only interpreter in this repository
    that imports both strictdoc and tree_sitter. The plain grammar derivation
    ships `$out/parser` with no python at all, so `ctypes` is what lets one
    interpreter serve both halves.

    `Language(int)` emits a DeprecationWarning on py-tree-sitter 0.25.2. It is
    cosmetic -- the int IS the documented C pointer -- and it is suppressed
    here rather than avoided, because avoiding it means the python binding and
    its dependency tree.
    """
    if not parser_path:
        raise ExtractorError(
            f"no tree-sitter parser for symbol {symbol!r}: "
            + (
                f"{env_var} is unset or empty. It is set on the "
                "strictdoc-grammar-extract wrapper "
                "(packages/strictdoc-grammar/lib/mkExtract.nix); point it at a "
                "grammar derivation's ./parser to override."
                if env_var
                else "no path was given."
            )
        )
    if not os.path.exists(parser_path):
        raise ExtractorError(
            f"tree-sitter parser {parser_path!r} does not exist "
            f"(symbol {symbol!r})"
        )
    library = ctypes.CDLL(parser_path)
    try:
        entry_point = getattr(library, symbol)
    except AttributeError as error:
        raise ExtractorError(
            f"tree-sitter parser {parser_path!r} exports no {symbol!r}"
        ) from error
    entry_point.restype = ctypes.c_void_p
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        return Language(entry_point())


def join_name_nodes(context: ItemContext, separator: str = ".") -> str:
    """The default `id_of`: join every `@item.name` capture's text."""
    return separator.join(
        (node.text or b"").decode("utf-8") for node in context.name_nodes
    )


class TreeSitterExtractor:
    """Query-driven extraction of named items from one tree-sitter language."""

    def __init__(
        self,
        *,
        language: Language,
        element_queries: Mapping[str, str],
        id_of: Optional[Callable[[ItemContext], str]] = None,
        comment_node_types: Sequence[str] = ("comment",),
    ) -> None:
        if not element_queries:
            raise ExtractorError("element_queries is empty: nothing to extract")
        self.language = language
        self.element_queries = dict(element_queries)
        self.id_of = id_of if id_of is not None else join_name_nodes
        self.comment_node_types = tuple(comment_node_types)
        self._parser = Parser(language)
        self._compiled: dict[str, Query] = {}
        for kind, query_source in self.element_queries.items():
            self._compiled[kind] = self._compile(kind, query_source)

    # ── construction-time validation ─────────────────────────────────────

    def _compile(self, kind: str, query_source: str) -> Query:
        try:
            query = Query(self.language, query_source)
        except Exception as error:  # noqa: BLE001 - re-raised with the kind
            raise ExtractorError(
                f"element query {kind!r} does not compile against this "
                f"grammar: {error}"
            ) from error
        captures = {
            query.capture_name(index) for index in range(query.capture_count)
        }
        if ITEM_CAPTURE not in captures:
            raise ExtractorError(
                f"element query {kind!r} captures no @{ITEM_CAPTURE}; without "
                "it there is no node to take a byte range and line span from"
            )
        return query

    # ── extraction ───────────────────────────────────────────────────────

    def extract(
        self, source: bytes, file_path: Optional[str] = None
    ) -> list[ExtractedItem]:
        """Every item the element queries match, in source order."""
        if not source:
            return []
        tree = self._parser.parse(source)
        # A node that reaches EOF reports the row AFTER the last line when the
        # file ends in a newline, and strictdoc looks every line of an item up
        # in a table that holds only the real ones -- so an unclamped
        # `line_end` kills an export with a bare `error: <line>`. Counted the
        # way SourceFileStats counts, so the two agree exactly.
        last_line = max(1, len(source.splitlines()))
        claimed: dict[tuple[int, int], str] = {}
        items: list[ExtractedItem] = []
        for kind, query in self._compiled.items():
            for _pattern, captures in QueryCursor(query).matches(
                tree.root_node
            ):
                nodes = captures.get(ITEM_CAPTURE) or []
                if not nodes:
                    continue
                node = nodes[0]
                key = (node.start_byte, node.end_byte)
                if key in claimed:
                    # A more specific kind already claimed this node. See the
                    # ordering rule in the module header.
                    continue
                claimed[key] = kind
                context = ItemContext(
                    kind=kind,
                    node=node,
                    name_nodes=tuple(captures.get(NAME_CAPTURE) or ()),
                    source=source,
                    file_path=file_path,
                )
                items.append(self._item(context, last_line))
        items.sort(key=lambda item: (item.byte_begin, item.byte_end))
        return items

    def file_comment(self, source: bytes) -> Optional[FileComment]:
        """The comment run at the top of the file, if the file opens with one.

        A file-header comment is where a `@relation(..., scope=file)` marker
        lives. It is separate from `extract` because it belongs to no item.
        """
        if not source:
            return None
        root = self._parser.parse(source).root_node
        run: list[Node] = []
        for child in root.children:
            if child.type not in self.comment_node_types:
                break
            if run and child.start_point[0] != run[-1].end_point[0] + 1:
                break
            run.append(child)
        if not run:
            return None
        return FileComment(
            text=self._text_of(source, run[0].start_byte, run[-1].end_byte),
            line_begin=run[0].start_point[0] + 1,
            byte_begin=run[0].start_byte,
            byte_end=run[-1].end_byte,
        )

    # ── internals ────────────────────────────────────────────────────────

    def _item(self, context: ItemContext, last_line: int) -> ExtractedItem:
        node = context.node
        identifier = self.id_of(context)
        if not identifier:
            raise ExtractorError(
                f"id_of returned an empty identifier for a {context.kind!r} "
                f"item at line {node.start_point[0] + 1} of "
                f"{context.file_path or '<buffer>'}"
            )
        comments = self._leading_comments(node)
        text = line = begin = end = None
        if comments:
            begin = comments[0].start_byte
            end = comments[-1].end_byte
            text = self._text_of(context.source, begin, end)
            line = comments[0].start_point[0] + 1
        return ExtractedItem(
            kind=context.kind,
            identifier=identifier,
            # WITHOUT the comment: strictdoc's LanguageItem contract.
            line_begin=node.start_point[0] + 1,
            line_end=min(node.end_point[0] + 1, last_line),
            byte_begin=node.start_byte,
            byte_end=node.end_byte,
            comment_text=text,
            comment_line_begin=line,
            comment_byte_begin=begin,
            comment_byte_end=end,
        )

    def _leading_comments(self, node: Node) -> tuple[Node, ...]:
        """The run of comment lines immediately above `node`.

        THE ASCENT IS THE SUBTLE PART. The comment above the FIRST binding of
        an attribute set is not that binding's `prev_sibling` -- the enclosing
        `binding_set` starts at exactly the same byte, and the comment is ITS
        sibling. Ascending while the parent starts at the same byte as the
        item generalizes that to any grammar with the same shape, and stops at
        the first enclosing node that starts earlier (an `{` for instance), so
        it can never wander off into an unrelated comment.
        """
        anchor = node
        previous = anchor.prev_sibling
        while previous is None:
            parent = anchor.parent
            if parent is None or parent.start_byte != node.start_byte:
                return ()
            anchor = parent
            previous = anchor.prev_sibling
        run: list[Node] = []
        target_row = node.start_point[0]
        while previous is not None and previous.type in self.comment_node_types:
            # A blank line between the comment and what follows means the
            # comment documents something else.
            if previous.end_point[0] + 1 != target_row:
                break
            run.insert(0, previous)
            target_row = previous.start_point[0]
            previous = previous.prev_sibling
        return tuple(run)

    @staticmethod
    def _text_of(source: bytes, begin: int, end: int) -> str:
        return source[begin:end].decode("utf-8")


def find_item(
    items: Iterable[ExtractedItem], identifier: str
) -> Optional[ExtractedItem]:
    """The item a user's `ID:` would resolve to, or None.

    strictdoc resolves a forward `ID:` against `display_name` first and `name`
    second; here the two are one string, so this is the same lookup.
    """
    for item in items:
        if item.display_name == identifier:
            return item
    return None
