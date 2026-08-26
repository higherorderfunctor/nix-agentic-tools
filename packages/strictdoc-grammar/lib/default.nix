# Barrel for the four grammar-surface files. Wiring only — every layer's body
# lives in its own file so the generated ones can be overwritten wholesale.
#
# The dependency direction is fixed and one-way:
#
#   faithful  <- nothing
#   normalized <- faithful      (rewrites specific nodes; deep-merge in spirit)
#   emit       <- normalized    (needs the encoders to render values)
#   dsl        <- normalized    (sugar over the normalized types)
#
# SCAFFOLD: the four imports below are stubs/placeholders. The argument sets
# passed here are the contract the implementing sessions write against — a stub
# accepts them with `{...}:` and ignores them.
{lib}: let
  faithful = import ./faithful.nix {inherit lib;};
  normalized = import ./normalized.nix {inherit lib faithful;};
  emit = import ./emit.nix {inherit lib normalized;};
  dsl = import ./dsl.nix {inherit lib normalized;};
in {
  inherit dsl emit faithful normalized;
}
