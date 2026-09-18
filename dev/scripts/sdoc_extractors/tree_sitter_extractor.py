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

A THIRD rule is about ranges rather than order, and it is what lets a wrapping
grammar (TypeScript's `export_statement`, say) be added without editing any
query: when one kind matches the same id at two NESTED ranges, the OUTER one
wins and carries the comment. `_keep_outermost` and `_leading_comments` are
the two halves of that, and both are language-agnostic on purpose -- a new
language must not have to reach into this file.

── One more axis: SUB-GRAMMARS ──────────────────────────────────────────────

`injections={"indented_string_expression": bash_extractor}` reads an embedded
language out of its host -- bash inside a Nix `''...''` block. It is a whole
`TreeSitterExtractor` on the other side, so an embedded language costs nothing
this file does not already have. Everything about it lives in ONE section at
the bottom of the class; read that section, not this paragraph, for why the
parse is done with included ranges.
"""

from __future__ import annotations

import ctypes
import os
import warnings
from dataclasses import dataclass, replace
from typing import (
    Callable,
    Iterable,
    Mapping,
    NamedTuple,
    Optional,
    Sequence,
    Union,
)

from tree_sitter import (
    Language,
    Node,
    Parser,
    Point,
    Query,
    QueryCursor,
    Range,
)

#: The capture every element query must carry: the node that becomes the item.
ITEM_CAPTURE = "item.node"

#: The optional capture whose text the default `id_of` joins into an identifier.
NAME_CAPTURE = "item.name"

#: The capture the generated host query uses to find an injection's host node.
HOST_CAPTURE = "injection.host"


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


@dataclass(frozen=True)
class Injection:
    """One embedded sub-grammar: bash inside a Nix `''...''` string, say.

    `extractor` is a whole `TreeSitterExtractor` for the embedded language, so
    an injected language needs no code beyond its own module -- the same
    `element_queries` + `id_of` triple every top-level language fills in.

    `kind_prefix` keeps the two vocabularies apart. Bash's own `function` kind
    becomes `shell-function` when it is read out of a Nix file, so a reader's
    `kind_elements` map can route it and a rendered description says which
    language it came from.

    `host_id_of` names the HOST, and the injected item's id is
    `<host id><separator><item id>`. Nix passes the enclosing attrpath, which
    is what makes `text::sync_file` typeable in an `ID:` field. Left None, the
    host extractor's own `id_of` is used.

    `content_node_types` is what actually gets parsed. An indented Nix string
    is a mix of `string_fragment` and `interpolation` children, and handing the
    interpolations to bash would be handing it Nix source; taking only the
    fragments, as INCLUDED RANGES rather than as a copied slice, is also what
    keeps every line and byte offset ABSOLUTE in the host file.
    """

    extractor: "TreeSitterExtractor"
    kind_prefix: str = ""
    host_id_of: Optional[Callable[[ItemContext], str]] = None
    separator: str = "::"
    content_node_types: Sequence[str] = ("string_fragment",)


def _normalize_injections(
    injections: Optional[Mapping[str, Union["TreeSitterExtractor", Injection]]],
) -> dict:
    """Accept a bare extractor where the defaults are wanted."""
    normalized: dict[str, Injection] = {}
    for host_type, injection in (injections or {}).items():
        normalized[host_type] = (
            injection
            if isinstance(injection, Injection)
            else Injection(extractor=injection)
        )
    return normalized


class TreeSitterExtractor:
    """Query-driven extraction of named items from one tree-sitter language."""

    def __init__(
        self,
        *,
        language: Language,
        element_queries: Mapping[str, str],
        id_of: Optional[Callable[[ItemContext], str]] = None,
        comment_node_types: Sequence[str] = ("comment",),
        injections: Optional[
            Mapping[str, Union["TreeSitterExtractor", Injection]]
        ] = None,
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
        # Injections. Compiled here for the same reason the element queries
        # are: an unknown host node type must fail at CONSTRUCTION, naming the
        # type, rather than silently capturing nothing much later.
        self.injections = _normalize_injections(injections)
        self._host_queries: dict[str, Query] = {
            host_type: self._compile_host(host_type)
            for host_type in self.injections
        }
        self._ranged_parser: Optional[Parser] = None

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
        self,
        source: bytes,
        file_path: Optional[str] = None,
        *,
        ranges: Optional[Sequence[Range]] = None,
    ) -> list[ExtractedItem]:
        """Every item the element queries match, in source order.

        `ranges` restricts the parse to slices of `source` -- how an injected
        sub-grammar is read out of its host. See the injections section below.
        """
        if not source:
            return []
        tree = self._parse(source, ranges)
        # A node that reaches EOF reports the row AFTER the last line when the
        # file ends in a newline, and strictdoc looks every line of an item up
        # in a table that holds only the real ones -- so an unclamped
        # `line_end` kills an export with a bare `error: <line>`. Counted the
        # way SourceFileStats counts, so the two agree exactly.
        last_line = max(1, len(source.splitlines()))
        claimed: dict[tuple[int, int], str] = {}
        candidates: list[ExtractedItem] = []
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
                    # A more specific kind already claimed this EXACT node.
                    # See the ordering rule in the module header. A node
                    # matched twice at two DIFFERENT ranges -- a wrapper and
                    # what it wraps -- is a different problem, and
                    # `_keep_outermost` below is where it is settled.
                    continue
                claimed[key] = kind
                context = ItemContext(
                    kind=kind,
                    node=node,
                    name_nodes=tuple(captures.get(NAME_CAPTURE) or ()),
                    source=source,
                    file_path=file_path,
                )
                candidates.append(self._item(context, last_line))
        items = _keep_outermost(candidates)
        # Sub-grammars embedded in this one. Separate section below; nothing
        # above this line knows they exist.
        items.extend(self._injected_items(tree.root_node, source, file_path))
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

        THE ASCENT IS THE SUBTLE PART, and it has to clear TWO obstacles, not
        one. The comment above the FIRST binding of an attribute set is not
        that binding's `prev_sibling` -- the enclosing `binding_set` starts at
        exactly the same byte, and the comment is ITS sibling. And an item
        inside a WRAPPER -- a TypeScript `export_statement` around a
        `function_declaration`, a Nix `with lib;` before the expression the
        query captured -- has a `prev_sibling` that is not None and not a
        comment (the `export` or `=` token), so a loop that ascends only while
        `prev_sibling is None` never leaves the wrapper at all and the item is
        reported with NO comment.

        So this ascends past a non-comment sibling too, under two conditions
        that together keep it from wandering:

        * the ancestor STARTS ON THE SAME LINE as the item -- the wrapper
          case, and a superset of the same-byte case above; or
        * the ancestor is a SINGLE-CHILD WRAPPER, `child_count == 1` counting
          anonymous nodes, so it holds this item and literally nothing else.

        `child_count == 1` rather than `named_child_count == 1` is measured,
        not fussiness. A Nix `attrset_expression` has one NAMED child (its
        `binding_set`) plus two braces, so the looser test ascends out of the
        braces and hands the FILE-HEADER comment to the set's first binding --
        a comment that documents the file, attached to an item, and rendered
        as a second identical marker.
        """
        anchor = node
        while True:
            previous = anchor.prev_sibling
            run = self._comment_run(previous, anchor.start_point[0])
            if run:
                return run
            if previous is not None and previous.type in self.comment_node_types:
                # A comment IS there, separated by a blank line: it documents
                # something else, and ascending past it would find one that
                # documents even less.
                return ()
            parent = anchor.parent
            if parent is None:
                return ()
            if not (
                parent.start_point[0] == node.start_point[0]
                or _is_single_child_wrapper(parent, anchor)
            ):
                return ()
            anchor = parent

    def _comment_run(
        self, previous: Optional[Node], start_row: int
    ) -> tuple[Node, ...]:
        """The comment lines running upward from `start_row`, unbroken."""
        run: list[Node] = []
        target_row = start_row
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

    # ── injected sub-grammars ────────────────────────────────────────────
    #
    # SELF-CONTAINED SECTION. Everything below is reached from exactly two
    # lines outside it -- `self._parse(...)` and `self._injected_items(...)`
    # in `extract` -- plus the `injections` block in `__init__` and the
    # `Injection` record above the class. Nothing here touches the
    # element-query loop, the claim map, `_keep_outermost` or comment
    # attachment.
    #
    # ── Why INCLUDED RANGES rather than a copied slice ───────────────────
    #
    # Both routes parse the same bytes. Only this one keeps the ANSWERS in the
    # host file's coordinate system: tree-sitter reports `start_byte` and
    # `start_point` in the ORIGINAL buffer when a parse was restricted with
    # `Parser.included_ranges`, so an injected item's line span is directly
    # usable as a `.nix` line span. Re-parsing a `source[a:b]` slice would
    # need every byte offset and every row corrected by hand, and the row
    # correction is not even a constant -- an indented Nix string's content
    # starts mid-line.
    #
    # It also disposes of interpolation for free. `${pkgs.coreutils}/bin/cp`
    # inside a shell string is NIX source sitting in the middle of a bash
    # script, and handing it to bash yields garbage. One included range per
    # `string_fragment` child means the interpolations are simply not in the
    # parse.

    def _compile_host(self, host_type: str) -> Query:
        """`(<host_type>) @injection.host`, validated against the grammar."""
        try:
            return Query(self.language, f"({host_type}) @{HOST_CAPTURE}")
        except Exception as error:  # noqa: BLE001 - re-raised with the type
            raise ExtractorError(
                f"injection host node type {host_type!r} does not exist in "
                f"this grammar: {error}"
            ) from error

    def _parse(self, source: bytes, ranges: Optional[Sequence[Range]]):
        """The tree `extract` works on: whole file, or only `ranges` of it."""
        if not ranges:
            return self._parser.parse(source)
        if self._ranged_parser is None:
            self._ranged_parser = Parser(self.language)
        self._ranged_parser.included_ranges = list(ranges)
        return self._ranged_parser.parse(source)

    def _injected_items(
        self, root: Node, source: bytes, file_path: Optional[str]
    ) -> list[ExtractedItem]:
        """Every item an injected grammar finds inside its host nodes."""
        if not self.injections:
            return []
        produced: list[ExtractedItem] = []
        for host_type, injection in self.injections.items():
            query = self._host_queries[host_type]
            for _pattern, captures in QueryCursor(query).matches(root):
                for host in captures.get(HOST_CAPTURE) or ():
                    produced.extend(
                        self._items_in_host(host, injection, source, file_path)
                    )
        return produced

    def _items_in_host(
        self,
        host: Node,
        injection: Injection,
        source: bytes,
        file_path: Optional[str],
    ) -> list[ExtractedItem]:
        ranges = _content_ranges(host, injection.content_node_types)
        if not ranges:
            return []
        items = injection.extractor.extract(source, file_path, ranges=ranges)
        if not items:
            return []
        id_of = injection.host_id_of or self.id_of
        prefix = id_of(
            ItemContext(
                kind=host.type,
                node=host,
                name_nodes=(),
                source=source,
                file_path=file_path,
            )
        )
        return [
            replace(
                item,
                kind=f"{injection.kind_prefix}{item.kind}",
                identifier=(
                    f"{prefix}{injection.separator}{item.identifier}"
                    if prefix
                    else item.identifier
                ),
            )
            for item in items
        ]


def _content_ranges(
    host: Node, content_node_types: Sequence[str]
) -> list[Range]:
    """One included range per content child of an injection host."""
    return [
        Range(
            start_point=Point(*child.start_point),
            end_point=Point(*child.end_point),
            start_byte=child.start_byte,
            end_byte=child.end_byte,
        )
        for child in host.children
        if child.type in content_node_types
        and child.end_byte > child.start_byte
    ]


def _is_single_child_wrapper(parent: Node, child: Node) -> bool:
    """`parent` holds `child` and nothing else -- no punctuation, no keyword."""
    return parent.child_count == 1 and parent.child(0) == child


def _keep_outermost(candidates: list[ExtractedItem]) -> list[ExtractedItem]:
    """Collapse a wrapper and what it wraps into ONE item: the outer one.

    THE PROBLEM THIS SOLVES IS A NEW LANGUAGE'S, NOT NIX'S, which is why it
    lives here and not in a queries module. A grammar that wraps its declared
    items -- TypeScript's `export_statement` around a `function_declaration`
    is the canonical one -- makes any honest query set match the same item
    twice, at two DIFFERENT byte ranges. Dedup on the exact range (which is
    all the kind-precedence claim above does) sees two distinct nodes and
    keeps both, so one declaration renders as two markers.

    Writing the queries to match only the inner node is not an escape: the
    inner node's range excludes the `export`, so the marker highlights half
    the declaration, and the leading comment sits above the WRAPPER.

    The rule: same kind AND same qualified id AND one range containing the
    other -> keep the OUTER. Its comment comes with it, because the item was
    built from the outer node and `_leading_comments` ascends from there.

    Deliberately NOT keyed on range alone. Two genuinely different items can
    nest -- a Nix `a.b` binding contains `a.b.c` -- and they differ in id, so
    the containment test never sees them.
    """
    if len(candidates) < 2:
        return list(candidates)
    dropped: set[int] = set()
    for index, inner in enumerate(candidates):
        for other, outer in enumerate(candidates):
            if other == index or other in dropped:
                continue
            if (outer.kind, outer.identifier) != (inner.kind, inner.identifier):
                continue
            contains = (
                outer.byte_begin <= inner.byte_begin
                and inner.byte_end <= outer.byte_end
                and (outer.byte_begin, outer.byte_end)
                != (inner.byte_begin, inner.byte_end)
            )
            if contains:
                dropped.add(index)
                break
    return [
        item for index, item in enumerate(candidates) if index not in dropped
    ]


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
