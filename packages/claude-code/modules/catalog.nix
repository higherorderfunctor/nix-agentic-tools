# Claude owns static Anthropic identities, available even when its runtime is disabled.
{lib, ...}: let
  ids = import ../lib/extracted-fact.nix {inherit lib;} "models";
  # Extraction supplies exact ids, with no additional vendor alias spellings.
  contribution = {
    models = lib.genAttrs ids (_: {
      maker = "anthropic";
      source = ["claude-code:models"];
    });
    vendors.claude.maker = "anthropic";
  };
in {
  # Leaf defaults merge CPA evidence and allow ordinary user field overrides.
  config.ai.catalog = lib.mapAttrsRecursive (_: lib.mkDefault) contribution;
}
