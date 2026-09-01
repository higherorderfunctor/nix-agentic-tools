# `emit` is the inner emitter composed with denormalize, and nothing else. The
# shape is MECH-EMIT-LAYER-BOUNDARY
# (docs/plans/strictdoc-tooling/mech-emit-layer-boundary.sdoc):
#
#   ./denormalize.nix  knows the TYPE MAPPING — a Nix bool becomes the literal
#                      True or False, an enum member becomes its bare string, a
#                      list becomes a comma-space join.
#   ./sgra.nix         knows the FILE FORMAT, takes values that are already all
#                      strings, and does no encoding at all. A pure renderer.
#   here               the two composed, entry point per entry point.
#
# One implementation, not two code paths: everything `emit.grammar` renders goes
# through both halves in order, so there is nothing for the halves to drift
# from.
#
# The composition is derived from the renderer's own attribute names rather than
# listed, so a node type added to both halves is composed without this file
# being edited — which also means ./sgra.nix must export renderers and nothing
# else.
{
  denormalize,
  lib,
  sgra,
  ...
}: let
  compose = name: value: sgra.${name} (denormalize.${name} value);
in
  (lib.genAttrs (lib.attrNames sgra) compose)
  // {
    # The encode halves, exposed so a converter pair can be audited from either
    # end rather than only through rendered output.
    inherit (denormalize) encoders;
  }
