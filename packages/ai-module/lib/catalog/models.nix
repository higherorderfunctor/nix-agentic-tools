# Pinned model identities; provider spellings never determine the maker.
{lib}: let
  facts = import ../../../../lib/extracted/facts.nix {inherit lib;};
  cpa = facts.get (facts.load {dir = ../../../cliproxyapi/extracted;}).aggregate;
  claude = facts.get (facts.load {dir = ../../../claude-code/extracted;}).aggregate "models";
  codex = facts.get (facts.load {dir = ../../../chatgpt-codex/extracted;}).aggregate "models";
  opencodeGo = cpa "opencodeGo";
  zAi = cpa "zAi";
  identity = maker: source: {
    inherit maker source;
    aliases = {};
  };
  native = maker: source: ids: lib.genAttrs ids (_: identity maker source);
  # An undisclosed maker keeps its own identity, never a guessed vendor.
  goMakerFacts.iceman-contributor-free = {
    maker = "iceman";
    source = "dcaf19f9:packages/delegate-routing/lib/opencode-go.nix:132";
  };
  # canonical_id carries the maker namespace; owned_by is the serving vendor.
  goModels = lib.mapAttrs (id: model: let
    canonical = model.canonical_id or null;
    namespace =
      if canonical == null
      then null
      else lib.head (lib.splitString "/" canonical);
  in
    (identity (
      if namespace == "zhipuai"
      then "zhipu"
      else namespace
    ) "cliproxyapi:opencodeGo.models.${id}")
    // (goMakerFacts.${id} or {})
    // {
      aliases.opencode-go = lib.optional (canonical != null) canonical;
    })
  opencodeGo.models;
  defaults = {
    models =
      native "anthropic" "claude-code:models" claude
      // native "openai" "chatgpt-codex:models" (map (model: model.slug) codex)
      // native "zhipu" "cliproxyapi:zAi.models" zAi.models
      // goModels;
    providers = {
      claude.maker = "anthropic";
      codex.maker = "openai";
    };
  };
in {
  inherit defaults opencodeGo zAi;
}
