# Codex contributes static OpenAI identities from its own measured model list.
{lib, ...}: let
  # The owner reads the aggregate directly; no catalog core imports owner facts.
  facts = import ../../../lib/extracted/facts.nix {inherit lib;};
  # The models fact is a list of records, with slug carrying each canonical id.
  models = facts.get (facts.load {dir = ../extracted;}).aggregate "models";
in {
  # Leaf defaults merge CPA evidence while ordinary user fields win.
  config.ai.catalog = lib.mapAttrsRecursive (_: lib.mkDefault) {
    models = lib.genAttrs (map (model: model.slug) models) (_: {
      maker = "openai";
      source = ["chatgpt-codex:models"];
    });
    vendors.codex.maker = "openai";
  };
}
