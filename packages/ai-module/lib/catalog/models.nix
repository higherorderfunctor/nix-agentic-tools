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
  nativeModels =
    native "anthropic" "claude-code:models" claude
    // native "openai" "chatgpt-codex:models" (map (model: model.slug) codex)
    // native "zhipu" "cliproxyapi:zAi.models" zAi.models;
  # Maker facts ported from dcaf19f9:packages/delegate-routing/lib/opencode-go.nix:60-259.
  # Native Claude, GLM and GPT offers use their native maker identities.
  # iceman is undisclosed, not an attribution to another vendor. Provider
  # namespaces (notably moonshotai) are aliases, never maker identities.
  goMakers = {
    "beam-free" = "reflection";
    "deepseek-v4-pro" = "deepseek";
    "deepseek-v4.1-flash" = "deepseek";
    "gemini-4-argon" = "google";
    "grok-4.7" = "xai";
    "hy3" = "tencent";
    "hy4" = "tencent";
    "hy4-preview" = "tencent";
    "iceman-contributor-free" = "iceman";
    "kimi-k2.7-code" = "moonshot";
    "kimi-k3" = "moonshot";
    "kimi-k3.1-pro" = "moonshot";
    "longcat-2.0" = "meituan";
    "longcat-2.5-free" = "meituan";
    "mimo-v2.6-flash" = "xiaomi";
    "mimo-v2.6-pro" = "xiaomi";
    "minimax-m3" = "minimax";
    "minimax-m3.1-flash" = "minimax";
    "muse-spark-1.2-contributor" = "meta";
    "muse-spark-1.3-contributor" = "meta";
    "qwen3.7-plus" = "alibaba";
    "qwen3.8-flash" = "alibaba";
    "qwen3.8-max" = "alibaba";
    "step-5-preview" = "stepfun";
  };
  goModels = lib.mapAttrs (id: model:
    (nativeModels.${
        id
      } or (identity (goMakers.${id} or (throw "ai.catalog: Go offer ${builtins.toJSON id} has no maker identity."))
        "cliproxyapi:opencodeGo.models.${id}; dcaf19f9:packages/delegate-routing/lib/opencode-go.nix:60-259"))
    // {
      aliases.opencode-go = lib.optional (model ? canonical_id) model.canonical_id;
    })
  opencodeGo.models;
  defaults = {
    models = nativeModels // goModels;
    providers = {
      claude.maker = "anthropic";
      codex.maker = "openai";
    };
  };
in {
  inherit defaults opencodeGo zAi;
}
