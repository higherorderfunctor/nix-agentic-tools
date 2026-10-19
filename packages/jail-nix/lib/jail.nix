# The `lib.ai.jail` value, also bound into modules as `ai.internal.jail`
# (lib/facets/repository.nix `moduleInternals`), so both read one definition.
{inputs}: {
  inherit (inputs.jail-nix.lib) extend init;
  # `combinators pkgs` is an `additionalCombinators` function for `extend`.
  combinators = import ./combinators.nix;
  src = inputs.jail-nix.outPath;
}
