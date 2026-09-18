# cspell:ignore attrpath dlopens monkeypatches recompiles sdoc
"""The adapter: `ExtractedItem` records in, a strictdoc source reader out.

EVERY STRICTDOC IMPORT IN THIS PACKAGE LIVES HERE. `tree_sitter_extractor.py`
and `nix.py` stay importable from any interpreter with `tree_sitter`, so the
extractor can be run and inspected even when strictdoc is absent or broken.

── The reader contract is a DUCK TYPE ───────────────────────────────────────

There is no ABC, no Protocol and no entry point.
`SourceCodeReaderRegistry.get_reader` returns a Union of five concrete
classes, and a reader needs exactly four members:

    supported_elements()  @staticmethod -> ["function", "class"]
    __init__(custom_tags: Optional[set[str]] = None)
    read(input_buffer: bytes, file_path: Optional[str] = None)
    read_from_file(path: str)

Only the Markdown reader consults `supported_elements`; the `.sdoc` path never
does.

── ELEMENT is a CLOSED vocabulary, so the kind travels in the description ───

`RangeMarkerType` is `{FUNCTION, CLASS, FILE}` and the marker lexer closes the
set a second time; `LanguageItem` has no kind field at all. So an item's KIND
-- module, option, binding -- CANNOT be an ELEMENT value. It reaches the
rendered page through `LanguageItemMarker.set_description`, which is exactly
what strictdoc's own Rust reader does to show `impl`, `trait` and `mod`.

Write `ELEMENT: function` (or `class`) in the `.sdoc` File relation and let
the description say `option services.foo.enable`.

── Two line numbers that are deliberately different ─────────────────────────

`LanguageItem.line_begin` EXCLUDES leading comment lines -- its own docstring
says so, and it is what the source view highlights. `MarkerParser`'s
`line_start` INCLUDES them -- its docstring says the opposite, and it is what
positions the marker. Passing one number to both misplaces one of the two.
`ExtractedItem` carries both (`line_begin`, `line_begin_with_comment`) so the
distinction cannot be lost by accident.

── The silent-drop hazard this adapter cannot fix ───────────────────────────

A forward `ID:` that matches no item is NOT an error: strictdoc exits 0,
creates no marker, and the relation is absent from both the document page and
the source page. An unknown ELEMENT degrades to a whole-file marker just as
quietly. A wrong id and a right id are indistinguishable from the outside, so
every proof has to assert the marker is PRESENT in the rendered source page.
`__main__.py` is the loud counterpart: it exits 1 on an id that resolves to
nothing.

── The second half of this file: WHICH READER, and the NULL one ─────────────

`register_source_extractors` REPLACES strictdoc's reader registry rather than
extending it. Every source file in the tree is routed by a GLOB against a
manifest the project config owns; a file no glob claims is read by
`NullSourceReader`, which runs no parser at all.

NO INTERNAL STRICTDOC READER IS EVER REACHED -- not the generic textX one, and
not the Python, C, Robot or Rust ones either. That is the operator's ruling of
2026-09-02 ("i'd even be okay with disabling all internal parsers and only
scanning for configured langs") and it is deliberate: the generic reader
recompiles a textX grammar per file and was measured at 77% of a 15.4 s cold
export over ~1300 files. `.py` and `.rs` therefore contribute no items until a
tree-sitter extractor for them is added to the manifest.

── GLOBS DECIDE WHAT IS PARSED, NOT WHAT IS INDEXED ─────────────────────────

The walk is untouched -- 0.3 s, and every file still enters the index. That is
what keeps a whole-file `TYPE: File` relation to a `.md`, a `.js` or anything
else resolving: the File-relation resolver's predicate is "was indexed", not
"has items", so a path missing from the index is a HARD ERROR while a path
with no items is fine. Narrowing `include_source_paths` instead would have
turned every such relation into that hard error
(docs/plans/strictdoc-tooling/mech-file-relation-existence.sdoc).

`NullSourceReader` still computes `SourceFileStats`, because a whole-file
forward marker's end line comes from `file_stats.lines_total`. That is one
read and one `splitlines()`, against a textX metamodel compile.
"""

from __future__ import annotations

from collections import Counter
from typing import Callable, Mapping, Optional, Sequence

from strictdoc.backend.sdoc_source_code.constants import FunctionAttribute
from strictdoc.backend.sdoc_source_code.marker_parser import MarkerParser
from strictdoc.backend.sdoc_source_code.models.language import LanguageItem
from strictdoc.backend.sdoc_source_code.models.language_item_marker import (
    LanguageItemMarker,
    RangeMarkerType,
)
from strictdoc.backend.sdoc_source_code.models.source_file_info import (
    SourceFileTraceabilityInfo,
)
from strictdoc.backend.sdoc_source_code.models.source_location import ByteRange
from strictdoc.backend.sdoc_source_code.parse_context import ParseContext
from strictdoc.backend.sdoc_source_code.processors.general_language_marker_processors import (  # noqa: E501
    language_item_marker_processor,
    source_file_traceability_info_processor,
)
from strictdoc.helpers.file_stats import SourceFileStats
from strictdoc.helpers.file_system import file_open_read_bytes

from . import registry
from .tree_sitter_extractor import ExtractedItem, TreeSitterExtractor

#: What strictdoc's ELEMENT field accepts. Nothing else may be emitted.
SUPPORTED_ELEMENTS = ["function", "class"]

_SCOPE_FOR_ELEMENT = {
    "function": "function",
    "class": "class",
}


class TreeSitterSourceReader:
    """A strictdoc source-code reader backed by a `TreeSitterExtractor`."""

    def __init__(
        self,
        custom_tags: Optional[set] = None,
        *,
        extractor: TreeSitterExtractor,
        kind_elements: Optional[Mapping[str, str]] = None,
        default_element: str = "function",
    ) -> None:
        self.custom_tags = custom_tags
        self.extractor = extractor
        self.kind_elements = dict(kind_elements or {})
        self.default_element = default_element
        unknown = {
            element
            for element in (*self.kind_elements.values(), default_element)
            if element not in SUPPORTED_ELEMENTS
        }
        if unknown:
            raise ValueError(
                f"kind_elements maps to {sorted(unknown)}, but strictdoc's "
                f"ELEMENT vocabulary is closed to {SUPPORTED_ELEMENTS}. The "
                "kind belongs in the description, not in ELEMENT."
            )

    @staticmethod
    def supported_elements() -> list:
        return list(SUPPORTED_ELEMENTS)

    # ── the reader contract ──────────────────────────────────────────────

    def read(
        self, input_buffer: bytes, file_path: Optional[str] = None
    ) -> SourceFileTraceabilityInfo:
        info = SourceFileTraceabilityInfo([])
        if not input_buffer:
            return info

        file_stats = SourceFileStats.create(input_buffer)
        parse_context = ParseContext(file_path, file_stats)

        items = self.extractor.extract(input_buffer, file_path)

        # A header comment that also sits directly above the first item is ONE
        # comment, and parsing it twice registers every marker in it twice --
        # measured as two identical range pointers on one requirement. The item
        # wins, because only the item route can attach a kind-carrying
        # description; the file pass covers the case where a blank line, or
        # anything else, separates the header from the first item.
        claimed = {
            (item.comment_byte_begin, item.comment_byte_end)
            for item in items
            if item.has_comment
        }
        self._read_file_comment(
            input_buffer, parse_context, file_stats, claimed
        )

        for item in items:
            markers = self._markers_for(item, parse_context)
            language_item = LanguageItem(
                parent=info,
                name=item.identifier,
                display_name=item.display_name,
                # WITHOUT leading comment lines. See the module header.
                line_begin=item.line_begin,
                line_end=item.line_end,
                code_byte_range=ByteRange(item.byte_begin, item.byte_end),
                child_functions=[],
                markers=markers,
                attributes={FunctionAttribute.DEFINITION},
            )
            # LanguageItem has no kind field, and this is not one: it is a
            # side channel `register.register_forward_descriptions` reads so a
            # FORWARD relation can render the kind too. Nothing in strictdoc
            # looks at it, and it survives the pickle cache.
            language_item.sdoc_kind = item.kind
            info.functions.append(language_item)
            if markers:
                info.ng_map_names_to_markers[item.identifier] = markers

        source_file_traceability_info_processor(info, parse_context)
        return info

    def read_from_file(self, path: str) -> SourceFileTraceabilityInfo:
        with file_open_read_bytes(path) as source_file:
            return self.read(source_file.read(), file_path=path)

    # ── internals ────────────────────────────────────────────────────────

    def _read_file_comment(
        self,
        input_buffer: bytes,
        parse_context: ParseContext,
        file_stats: SourceFileStats,
        claimed: set,
    ) -> None:
        comment = self.extractor.file_comment(input_buffer)
        if comment is None:
            return
        if (comment.byte_begin, comment.byte_end) in claimed:
            return
        source_node = MarkerParser.parse(
            input_string=comment.text,
            line_start=1,
            line_end=file_stats.lines_total,
            comment_line_start=comment.line_begin,
            comment_byte_range=ByteRange(comment.byte_begin, comment.byte_end),
            filename=parse_context.filename,
            custom_tags=self.custom_tags,
            default_scope="file",
        )
        for marker in source_node.markers:
            if (
                isinstance(marker, LanguageItemMarker)
                and marker.scope == RangeMarkerType.FILE
            ):
                language_item_marker_processor(marker, parse_context)

    def _markers_for(
        self, item: ExtractedItem, parse_context: ParseContext
    ) -> list:
        if not item.has_comment:
            return []
        element = self.kind_elements.get(item.kind, self.default_element)
        source_node = MarkerParser.parse(
            input_string=item.comment_text,
            # WITH leading comment lines. See the module header.
            line_start=item.line_begin_with_comment,
            line_end=item.line_end,
            comment_line_start=item.comment_line_begin,
            comment_byte_range=ByteRange(
                item.comment_byte_begin, item.comment_byte_end
            ),
            filename=parse_context.filename,
            # Kept equal to the description strictdoc renders, which is what
            # MarkerParser's own docstring asks for.
            entity_name=item.description,
            custom_tags=self.custom_tags,
            default_scope=_SCOPE_FOR_ELEMENT[element],
        )
        markers = []
        for marker in source_node.markers:
            if not isinstance(marker, LanguageItemMarker):
                continue
            # THE ONLY channel the kind travels on.
            marker.set_description(item.description)
            language_item_marker_processor(marker, parse_context)
            markers.append(marker)
        return markers


def make_reader_factory(
    extractor: TreeSitterExtractor,
    kind_elements: Optional[Mapping[str, str]] = None,
):
    """A `custom_tags -> reader` callable, sharing one compiled extractor.

    Building an extractor dlopens a grammar and compiles every query, so it is
    built once and reused; `get_reader` is called per source file.
    """

    def factory(custom_tags: Optional[set] = None) -> TreeSitterSourceReader:
        return TreeSitterSourceReader(
            custom_tags,
            extractor=extractor,
            kind_elements=kind_elements,
        )

    return factory


# ── the glob manifest, the null reader, and the registry replacement ────────
#
# One section, because the three are one mechanism: a path -> reader decision
# that never falls through to strictdoc.


#: What was routed where, by glob pattern, plus `null` for everything else.
#: A COUNTER RATHER THAN A LOG because the interesting assertion is a NUMBER --
#: "the null reader served 1,2xx files and the textX reader was constructed
#: zero times". Reset it with `reset_routing_stats()` before a measured run.
#:
#: WARM RUNS COUNT ZERO, and that is not a bug. strictdoc's PickleCache answers
#: before `get_reader` is ever called, so a second export over an unchanged
#: tree routes nothing at all.
ROUTING_STATS: Counter = Counter()

#: The key `ROUTING_STATS` uses for a file no glob claimed.
NULL_ROUTE = "null"


def reset_routing_stats() -> None:
    ROUTING_STATS.clear()


class NullSourceReader:
    """A reader that reads nothing, for a file no extractor is configured for.

    It is not a no-op: `file_stats` is load-bearing. A whole-file forward
    marker takes its end line from `file_stats.lines_total`, and coverage
    accounting indexes `file_stats.lines_info` by line number, so an
    unpopulated one raises a `KeyError` deep inside the traceability index the
    moment anything points at the file.

    What it does NOT do is parse. No textX metamodel, no tree-sitter, no
    marker scan -- so a `@relation(...)` written in a comment of an unclaimed
    file is INVISIBLE. Backward relations exist only in files the manifest
    claims; forward `TYPE: File` relations, which live in the `.sdoc` and not
    in the source, keep working for every indexed file.
    """

    def __init__(self, custom_tags: Optional[set] = None) -> None:
        self.custom_tags = custom_tags

    @staticmethod
    def supported_elements() -> list:
        return []

    def read(
        self,
        input_buffer: bytes,
        file_path: Optional[str] = None,  # noqa: ARG002
    ) -> SourceFileTraceabilityInfo:
        info = SourceFileTraceabilityInfo([])
        info.file_stats = SourceFileStats.create(input_buffer)
        return info

    def read_from_file(self, path: str) -> SourceFileTraceabilityInfo:
        with file_open_read_bytes(path) as source_file:
            return self.read(source_file.read(), file_path=path)


class GlobRoutingReader:
    """The one reader strictdoc gets, which picks the real one per file.

    ROUTING HAPPENS HERE RATHER THAN IN THE REGISTRY PATCH because
    `get_reader` is handed the path but the patch's own factories are not:
    `register_readers` keys on a SUFFIX, and a glob manifest is not a set of
    suffixes. Registering this class under the universal route `""` and
    deciding inside `read_from_file` keeps `register.py` -- with its
    fail-closed shape checks and its idempotence -- as the only place that
    monkeypatches strictdoc.

    Matching is `registry.matches_glob` over `registry.relative_to`, which is
    the SAME matcher the write path validates an `ID:` with. A second matcher
    here would be a second thing obliged to agree, and the disagreement is
    silent in the worst direction: a relation the writer accepted because its
    glob matched, dropped at read time because this one did not.

    First matching pattern wins, in manifest order.
    """

    def __init__(
        self,
        custom_tags: Optional[set] = None,
        *,
        routes: Sequence,
        path_root: Optional[str] = None,
        fallback: Callable[..., object] = NullSourceReader,
    ) -> None:
        self.custom_tags = custom_tags
        self.routes = tuple(routes)
        self.path_root = path_root
        self.fallback = fallback

    @staticmethod
    def supported_elements() -> list:
        return list(SUPPORTED_ELEMENTS)

    # ── the reader contract ──────────────────────────────────────────────

    def read(
        self, input_buffer: bytes, file_path: Optional[str] = None
    ) -> SourceFileTraceabilityInfo:
        return self._reader_for(file_path).read(input_buffer, file_path)

    def read_from_file(self, path: str) -> SourceFileTraceabilityInfo:
        return self._reader_for(path).read_from_file(path)

    # ── internals ────────────────────────────────────────────────────────

    def _reader_for(self, path: Optional[str]):
        pattern, factory = self._route_for(path)
        ROUTING_STATS[pattern] += 1
        return factory(self.custom_tags)

    def _route_for(self, path: Optional[str]):
        if path is not None:
            # strictdoc hands the reader an ABSOLUTE path; the manifest is
            # written repo-relative, which is what keeps `packages/**` from
            # also claiming a vendored copy nested anywhere in the tree.
            relative = registry.relative_to(path, self.path_root)
            for pattern, factory in self.routes:
                if registry.matches_glob(pattern, relative):
                    return pattern, factory
        return NULL_ROUTE, self.fallback


def register_source_extractors(
    extractors: Mapping[str, Callable[..., object]],
    *,
    path_root: Optional[str] = None,
    fallback: Callable[..., object] = NullSourceReader,
) -> bool:
    """Install `extractors` as THE source-reader manifest. Returns as `register_readers`.

    `extractors` maps a glob to a `custom_tags -> reader` factory. The
    universal `""` suffix route is what makes this a REPLACEMENT rather than
    an extension: `"anything".endswith("")` is True, so `register_readers`
    never reaches the original registry and no internal strictdoc reader is
    constructed for any file.
    """
    from .register import register_readers

    routes = tuple(extractors.items())

    def factory(custom_tags: Optional[set] = None) -> GlobRoutingReader:
        return GlobRoutingReader(
            custom_tags,
            routes=routes,
            path_root=path_root,
            fallback=fallback,
        )

    return register_readers({"": factory})
