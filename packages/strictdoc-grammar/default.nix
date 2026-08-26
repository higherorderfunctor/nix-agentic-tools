# Per-package barrel for the typed `.sgra` grammar surface
# (SLICE-GRAMMAR-FROM-NIX, docs/plans/strictdoc-tooling/03-executable-rules.sdoc).
# The design of record is docs/implementation-brief.md, co-located here.
#
# Three layers, and the layering is real rather than a reasoning aid — an error
# is traceable to the layer it came from:
#
#   lib/faithful.nix    GENERATED  exactly what a .sgra file can express
#   lib/normalized.nix  GENERATED  faithful with named converters applied
#   lib/dsl.nix         hand-written sugar over normalized; cannot weaken it
#   lib/emit.nix        normalized values -> .sgra source text (encode only)
#
# Types flow UP from strictdoc at generation time; values flow DOWN from the DSL
# at authoring time. The extractor that WRITES the two generated files lives in
# extract/ and runs outside Nix — nothing here parses strictdoc at evaluation.
#
# General purpose and intended for publication: this repository's five node
# types are one consumer of the surface, not part of it.
{
  docs = ./docs;
  lib.ai.strictdocGrammar = import ./lib;
}
