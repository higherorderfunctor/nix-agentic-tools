# Codex-specific factory-of-factory.
{
  lib,
  pkgs,
  ...
}: let
  codexExtracted = builtins.fromJSON (builtins.readFile ../../../overlays/chatgpt-codex-extracted.json);
  helpers = import ../../../lib/ai/hm-helpers.nix {inherit lib;};
  tomlFormat = pkgs.formats.toml {};

  stableFeatureNames = map (feature: feature.name) (
    builtins.filter (feature: feature.maturity == "stable") codexExtracted.features
  );
  reasoningEffortLevels = lib.unique (
    lib.concatMap (model: model.reasoningLevels) codexExtracted.models
  );

  projectIgnoredKeys = [
    "apps_mcp_product_sku"
    "chatgpt_base_url"
    "experimental_realtime_ws_base_url"
    "model_provider"
    "model_providers"
    "notify"
    "openai_base_url"
    "otel"
    "profile"
    "profiles"
  ];

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
      settings = lib.mkOption {
        type = lib.types.submodule {
          freeformType = tomlFormat.type;
          options = {
            features = lib.mkOption {
              type = lib.types.submodule {
                freeformType = lib.types.attrsOf lib.types.bool;
                options = lib.genAttrs stableFeatureNames (_:
                  lib.mkOption {
                    type = lib.types.nullOr lib.types.bool;
                    default = null;
                  });
              };
              default = {};
              description = ''
                Codex feature toggles. Stable flags extracted from the pinned
                binary are typed; additional boolean flags remain available
                for experimental and forward-compatible use.
              '';
            };
            model = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              description = ''
                Default Codex model. The pinned binary's model catalog is a
                non-enforcing hint because account and provider availability
                can add valid model identifiers dynamically.
              '';
            };
            model_reasoning_effort = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum reasoningEffortLevels);
              default = null;
              description = ''
                Default reasoning effort for supported models. Values come
                from the model metadata extracted from the pinned binary.
              '';
            };
            personality = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum ["friendly" "none" "pragmatic"]);
              default = null;
              description = "Default communication style for supported models.";
            };
            web_search = lib.mkOption {
              type = lib.types.nullOr (lib.types.enum ["cached" "disabled" "indexed" "live"]);
              default = null;
              description = "Codex web-search mode.";
            };
          };
        };
        default = {};
        description = ''
          Codex config.toml settings. Common stable keys are typed; unknown
          TOML-compatible keys are accepted as a native escape hatch. Home
          Manager writes user config, while devenv writes trusted-project
          config and rejects keys Codex ignores at project scope.
        '';
      };
    };

    hm.config = {
      cfg,
      mergedInstructions,
      mergedRules,
      mergedSkills,
      topContext,
      topSettings,
      ...
    }: let
      agentsMd = mkAgentsMd {inherit cfg mergedInstructions mergedRules topContext;};
      settings = helpers.filterNulls cfg.settings;
    in {
      ai.codex.settings = lib.mkIf (topSettings.reasoningEffort != null) {
        model_reasoning_effort = lib.mkDefault topSettings.reasoningEffort;
      };
      assertions =
        mkPathAssertions {inherit mergedInstructions mergedRules;}
        ++ [
          (mkSizeAssertion {inherit agentsMd cfg mergedInstructions mergedRules topContext;})
        ];
      home.file = lib.mkMerge [
        (lib.mkIf (agentsMd != "") {
          "${cfg.configDir}/AGENTS.md".text = agentsMd;
        })
        (helpers.mkSkillEntries ".agents" mergedSkills)
        (lib.mkIf (settings != {}) {
          "${cfg.configDir}/config.toml".source = tomlFormat.generate "codex-config.toml" settings;
        })
      ];
      home.packages = [cfg.package];
    };

    devenv.config = {
      cfg,
      mergedInstructions,
      mergedRules,
      mergedSkills,
      topContext,
      topSettings,
      ...
    }: let
      agentsMd = mkAgentsMd {inherit cfg mergedInstructions mergedRules topContext;};
      settings = helpers.filterNulls cfg.settings;
      ignoredSettings = lib.intersectLists projectIgnoredKeys (builtins.attrNames settings);
    in {
      ai.codex.settings = lib.mkIf (topSettings.reasoningEffort != null) {
        model_reasoning_effort = lib.mkDefault topSettings.reasoningEffort;
      };
      assertions =
        mkPathAssertions {inherit mergedInstructions mergedRules;}
        ++ [
          (mkSizeAssertion {inherit agentsMd cfg mergedInstructions mergedRules topContext;})
          {
            assertion = ignoredSettings == [];
            message = ''
              ai.codex.settings contains keys Codex ignores in project config:
              ${lib.concatStringsSep ", " ignoredSettings}. Move them to the
              Home Manager user-level configuration.
            '';
          }
        ];
      files = lib.mkMerge [
        (lib.mkIf (agentsMd != "") {
          "AGENTS.md".text = agentsMd;
        })
        (helpers.mkDevenvSkillEntries ".agents" mergedSkills)
        (lib.mkIf (settings != {}) {
          ".codex/config.toml".source = tomlFormat.generate "codex-project-config.toml" settings;
        })
      ];
      packages = [cfg.package];
    };
  }
