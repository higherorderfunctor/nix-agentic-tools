# cspell:ignore sdoc
"""Tree-sitter source extraction for this repository's `.sdoc` design graph.

Three layers, and the split is what makes a new language cheap:

* `tree_sitter_extractor` -- language-agnostic, NO strictdoc import. Queries
  in, plain `ExtractedItem` records out.
* `<language>` (`nix`) -- a grammar, an `element_queries` dict and an `id_of`.
  The whole per-language surface.
* `strictdoc_reader` -- the adapter that turns records into a strictdoc source
  reader, and `register` -- the `get_reader` patch that installs it.

Adding TypeScript is a grammar plus a queries module plus one entry in the
registration dict. Nothing else moves.

Importing this package does NOT import strictdoc: `strictdoc_reader` and
`register` are imported explicitly by whoever needs them.
"""

from .nix import (
    NIX_ELEMENT_QUERIES,
    NIX_KIND_ELEMENTS,
    NIX_PARSER_ENV,
    nix_extractor,
)
from .tree_sitter_extractor import (
    ExtractedItem,
    ExtractorError,
    FileComment,
    ItemContext,
    TreeSitterExtractor,
    find_item,
    load_language,
)

__all__ = [
    "NIX_ELEMENT_QUERIES",
    "NIX_KIND_ELEMENTS",
    "NIX_PARSER_ENV",
    "ExtractedItem",
    "ExtractorError",
    "FileComment",
    "ItemContext",
    "TreeSitterExtractor",
    "find_item",
    "load_language",
    "nix_extractor",
]
