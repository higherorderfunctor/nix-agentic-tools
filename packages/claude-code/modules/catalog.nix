# Claude owns static Anthropic identities, available even when its runtime is disabled.
{lib, ...}: let
  # Read only this owner's aggregate; the models set is a list of strings.
  facts = import ../../../lib/extracted/facts.nix {inherit lib;};
  # The facts contract validates the set before genAttrs consumes its identifiers.
  ids = facts.get (facts.load {dir = ../extracted;}).aggregate "models";
  # Extraction supplies exact ids, with no additional provider alias spellings.
  contribution = {
    models = lib.genAttrs ids (_: {
      maker = "anthropic";
      source = ["claude-code:models"];
    });
    providers.claude.maker = "anthropic";
  };
in {
  # Leaf defaults merge CPA evidence and allow ordinary user field overrides.
  config.ai.catalog = lib.mapAttrsRecursive (_: lib.mkDefault) contribution;
}
