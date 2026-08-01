# Codex-specific factory-of-factory.
{
  lib,
  pkgs,
  ...
}: let
  resolveText = value:
    if builtins.isPath value
    then builtins.readFile value
    else value;

  mkAgentsMd = {
    cfg,
    mergedInstructions,
    mergedRules,
    topContext,
  }: let
    effectiveContext =
      if cfg.context != null
      then cfg.context
      else topContext;
    instructionChunks = map (instruction: let
      marker = lib.optionalString (instruction ? name) "<!-- instruction: ${instruction.name} -->\n";
    in
      marker
      + lib.ai.transformers.agentsmd.render (instruction
        // {text = resolveText instruction.text;}))
    mergedInstructions;
    ruleChunks = lib.mapAttrsToList (name: rule:
      "<!-- rule: ${name} -->\n"
      + lib.ai.transformers.agentsmd.render (rule
        // {text = resolveText rule.text;}))
    mergedRules;
    chunks =
      lib.optional (effectiveContext != null && effectiveContext != "") (resolveText effectiveContext)
      ++ instructionChunks
      ++ ruleChunks;
  in
    builtins.concatStringsSep "\n\n" chunks;

  mkScopeAssertions = {
    mergedInstructions,
    mergedRules,
  }:
    map (instruction: {
      assertion = (instruction.paths or null) == null;
      message = "ai.codex.instructions: scoped instructions are not supported yet; CX-005 will add explicit scope degradation semantics";
    })
    mergedInstructions
    ++ lib.mapAttrsToList (name: rule: {
      assertion = rule.paths == null;
      message = "ai.codex.rules.${name}: scoped rules are not supported yet; CX-005 will add explicit scope degradation semantics";
    })
    mergedRules;
in
  lib.ai.app.mkAiApp {
    name = "codex";
    transformers.markdown = lib.ai.transformers.agentsmd;
    defaults.package = pkgs.ai.chatgpt-codex;

    options = {
      configDir = lib.mkOption {
        type = lib.types.str;
        default = ".codex";
        description = ''
          Codex configuration directory relative to HOME. Home Manager writes
          global AGENTS.md here; devenv uses project-root AGENTS.md instead.
        '';
      };
      context = lib.mkOption {
        type = lib.types.nullOr (lib.types.either lib.types.lines lib.types.path);
        default = null;
        description = ''
          Codex-specific global context. When null, falls back to top-level
          `ai.context`.
        '';
        example = lib.literalExpression "./codex-context.md";
      };
    };

    hm.config = {
      cfg,
      mergedInstructions,
      mergedRules,
      topContext,
      ...
    }: let
      agentsMd = mkAgentsMd {inherit cfg mergedInstructions mergedRules topContext;};
    in {
      assertions = mkScopeAssertions {inherit mergedInstructions mergedRules;};
      home.file = lib.mkIf (agentsMd != "") {
        "${cfg.configDir}/AGENTS.md".text = agentsMd;
      };
      home.packages = [cfg.package];
    };

    devenv.config = {
      cfg,
      mergedInstructions,
      mergedRules,
      topContext,
      ...
    }: let
      agentsMd = mkAgentsMd {inherit cfg mergedInstructions mergedRules topContext;};
    in {
      assertions = mkScopeAssertions {inherit mergedInstructions mergedRules;};
      files = lib.mkIf (agentsMd != "") {
        "AGENTS.md".text = agentsMd;
      };
      packages = [cfg.package];
    };
  }
