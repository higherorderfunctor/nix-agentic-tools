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

  renderScope = paths:
    lib.optionalString (paths != null && paths != []) (
      "_Apply this guidance only when working with files matching: "
      + lib.concatMapStringsSep ", " (path: "`${path}`") paths
      + "_\n\n"
    );

  shouldRender = _name: fragment:
    (fragment.paths or null) == null || !(fragment.skipIfUnsupported or false);

  renderFragment = fragment:
    renderScope (fragment.paths or null)
    + lib.ai.transformers.agentsmd.render (fragment
      // {text = resolveText fragment.text;});

  mkInstructionChunk = instruction:
    lib.optionalString (instruction ? name) "<!-- instruction: ${instruction.name} -->\n"
    + renderFragment instruction;

  mkRuleChunk = name: rule:
    "<!-- rule: ${name} -->\n"
    + renderFragment rule;

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
    contextText =
      if effectiveContext == null
      then ""
      else resolveText effectiveContext;
    instructionChunks =
      map mkInstructionChunk
      (builtins.filter (shouldRender null) mergedInstructions);
    ruleChunks =
      lib.mapAttrsToList mkRuleChunk
      (lib.filterAttrs shouldRender mergedRules);
    chunks =
      lib.optional (contextText != "") contextText
      ++ instructionChunks
      ++ ruleChunks;
  in
    builtins.concatStringsSep "\n\n" chunks;

  mkSizeAssertion = {
    agentsMd,
    cfg,
    mergedInstructions,
    mergedRules,
    topContext,
  }: let
    effectiveContext =
      if cfg.context != null
      then cfg.context
      else topContext;
    size = text: builtins.stringLength (resolveText text);
    contextContribution =
      lib.optional (effectiveContext != null && resolveText effectiveContext != "")
      "context=${toString (size effectiveContext)} bytes";
    instructionContributions =
      lib.imap0 (index: instruction: "instruction:${instruction.name or (toString index)}=${toString (builtins.stringLength (mkInstructionChunk instruction))} bytes")
      (builtins.filter (shouldRender null) mergedInstructions);
    ruleContributions =
      lib.mapAttrsToList (name: rule: "rule:${name}=${toString (builtins.stringLength (mkRuleChunk name rule))} bytes")
      (lib.filterAttrs shouldRender mergedRules);
    renderedBytes = builtins.stringLength agentsMd;
  in {
    assertion = renderedBytes <= cfg.projectDocMaxBytes;
    message = ''
      Codex AGENTS.md renders to ${toString renderedBytes} bytes, exceeding
      ai.codex.projectDocMaxBytes (${toString cfg.projectDocMaxBytes} bytes).
      Contributions: ${lib.concatStringsSep ", " (contextContribution ++ instructionContributions ++ ruleContributions)}.
      Trim the contributing content or raise ai.codex.projectDocMaxBytes.
    '';
  };

  mkPathAssertions = {
    mergedInstructions,
    mergedRules,
  }:
    lib.imap0 (index: instruction: {
      assertion = (instruction.paths or null) != [];
      message = "ai.codex.instructions[${toString index}].paths must be null or a non-empty list";
    })
    mergedInstructions
    ++ lib.mapAttrsToList (name: rule: {
      assertion = rule.paths != [];
      message = "ai.codex.rules.${name}.paths must be null or a non-empty list";
    })
    mergedRules;
in
  lib.ai.app.mkAiApp {
    name = "codex";
    transformers.markdown = lib.ai.transformers.agentsmd;
    defaults.package = pkgs.ai.chatgpt-codex;

    options = {
      configDir = lib.mkOption {
        type = lib.types.addCheck lib.types.str (value:
          value
          != ""
          && !(lib.hasPrefix "/" value)
          && !(builtins.elem ".." (lib.splitString "/" value)));
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
      projectDocMaxBytes = lib.mkOption {
        type = lib.types.ints.positive;
        default = 32768;
        description = ''
          Maximum byte size of the generated Codex AGENTS.md. Evaluation fails
          before Codex can silently truncate content beyond this limit.
        '';
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
      assertions =
        mkPathAssertions {inherit mergedInstructions mergedRules;}
        ++ [
          (mkSizeAssertion {inherit agentsMd cfg mergedInstructions mergedRules topContext;})
        ];
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
      assertions =
        mkPathAssertions {inherit mergedInstructions mergedRules;}
        ++ [
          (mkSizeAssertion {inherit agentsMd cfg mergedInstructions mergedRules topContext;})
        ];
      files = lib.mkIf (agentsMd != "") {
        "AGENTS.md".text = agentsMd;
      };
      packages = [cfg.package];
    };
  }
