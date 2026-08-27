# Barrel for the grammar-surface files. Wiring only — every layer's body lives
# in its own file so the generated ones can be overwritten wholesale.
#
# The dependency direction is fixed and one-way:
#
#   faithful    <- nothing       (raw records; it takes no `lib`, having no types)
#   normalized  <- faithful      (builds the types from those records)
#   check       <- normalized    (applies the types to a value)
#   denormalize <- normalized    (applies each converter's ENCODE half)
#   sgra        <- nothing       (the file format; strings in, source text out)
#   emit        = sgra ∘ denormalize
#   dsl         <- normalized    (sugar over the normalized types)
#
# `render` is the whole chain in one call, and the only entry point a consumer
# needs: DSL values in, `.sgra` source text out, with the type check in between.
# Calling `emit.grammar` directly skips that check and is for testing the
# renderer, not for producing a file.
#
# `denormalize` and `sgra` are wired here and NOT re-exported. What the inner
# emitter is called, and whether it is published at all, is deliberately open
# (MECH-EMIT-LAYER-BOUNDARY's NOTES) — and an attribute is cheaper to add later
# than to remove once someone depends on it.
{lib}: let
  faithful = import ./faithful.nix;
  normalized = import ./normalized.nix {inherit lib faithful;};
  check = import ./check.nix {inherit lib normalized;};
  denormalize = import ./denormalize.nix {inherit lib normalized;};
  sgra = import ./sgra.nix {inherit lib;};
  emit = import ./emit.nix {inherit denormalize lib sgra;};
  dsl = import ./dsl.nix {inherit lib normalized;};
in {
  inherit check dsl emit faithful normalized;

  render = elements: emit.grammar (check.elements elements);
}
