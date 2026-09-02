# cspell:ignore attrpath dlopens sdoc
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
"""

from __future__ import annotations

from typing import Mapping, Optional

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
