# ============================================================================
# REFERENCE ONLY — PRE-FACTORY COPILOT-CLI HM MODULE.
#
# This file is NOT imported by any flake output. It is kept in the tree
# solely as source material for the copilot absorption work tracked in
# `docs/plan.md` "Ideal architecture gate → Absorption backlog".
#
# Target: absorb into `packages/copilot-cli/lib/mkCopilot.nix` as the
# config callback body. The current mkCopilot.nix has an empty
# `config = _: {}` — the mcp-config.json / lsp-config.json / skills /
# settings.json merge logic below needs to be ported there, writing
# to `home.file.*` (HM) or `files.*` (devenv) via the mkAiApp backend
# dispatch (another backlog item).
#
# Do NOT implement `programs.copilot-cli.*` as a target for fanout —
# the factory architecture replaces that upstream-style delegation
# with direct file writes from the factory config callback.
# ============================================================================
#
# programs.copilot-cli home-manager module (legacy).
# Mirrors upstream programs.claude-code conventions.
#
# Config directory: ~/.copilot/
# Mutable at runtime: config.json (trusted_folders, model selection)
# Immutable (Nix-managed): mcp-config.json, lsp-config.json, agents/, skills/
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.copilot-cli;
  jsonFormat = pkgs.formats.json {};
  hmHelpers = import ../../lib/hm-helpers.nix {inherit lib;};

  filteredSettings = hmHelpers.filterNulls cfg.settings;

  # Merge Nix-declared settings into existing mutable config.json on activation.
  # Preserves runtime-mutated keys (trusted_folders, etc.).
  settingsActivationScript = hmHelpers.mkSettingsActivationScript {
    inherit (cfg) configDir;
    configFile = "${cfg.configDir}/config.json";
    nixSettingsPath = jsonFormat.generate "copilot-cli-settings.json" filteredSettings;
    jq = "${pkgs.jq}/bin/jq";
  };

  # MCP server transformation (from programs.mcp.servers)
  transformedMcpServers =
    lib.optionalAttrs
    (cfg.enableMcpIntegration && config.programs.mcp.enable or false)
    (lib.mapAttrs (_: hmHelpers.mkMcpServer) config.programs.mcp.servers);

  allMcpServers = transformedMcpServers // cfg.mcpServers;

  # Wrapper args for MCP injection
  wrapperArgs = lib.optionals (allMcpServers != {}) [
    "--additional-mcp-config"
    "${jsonFormat.generate "copilot-mcp-config.json" {mcpServers = allMcpServers;}}"
  ];

  exclusiveInlineDirNames = ["agents" "instructions" "skills"];
in {
  options.programs.copilot-cli = {
    # --- Core ---
    enable = lib.mkEnableOption "GitHub Copilot CLI";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = pkgs.github-copilot-cli or null;
      defaultText = lib.literalExpression "pkgs.github-copilot-cli";
      description = "The copilot-cli package to install.";
    };

    configDir = lib.mkOption {
      type = lib.types.str;
      default = ".copilot";
      description = "Config directory relative to HOME. Override via COPILOT_HOME.";
    };

    # --- Settings (activation merge into config.json) ---
    settings = lib.mkOption {
      type = lib.types.submodule {
        freeformType = jsonFormat.type;
        options = {
          model = lib.mkOption {
            type = lib.types.nullOr lib.types.str;
            default = null;
            description = "Default model for Copilot CLI.";
          };
          theme = lib.mkOption {
            type = lib.types.nullOr (lib.types.enum ["dark" "light" "auto"]);
            default = null;
            description = "Color theme.";
          };
        };
      };
      default = {};
      description = ''
        JSON settings merged into ~/.copilot/config.json on activation.
        Runtime-mutated keys (trusted_folders, etc.) are preserved.
        Known keys are typed; unknown keys are accepted via freeformType.
      '';
      example = lib.literalExpression ''
        {
          autoUpdates = false;
          model = "claude-sonnet-4";
          theme = "dark";
        }
      '';
    };

    # --- MCP servers ---
    mcpServers = lib.mkOption {
      type = lib.types.attrsOf jsonFormat.type;
      default = {};
      description = "MCP server definitions. Injected via --additional-mcp-config.";
    };

    enableMcpIntegration = lib.mkEnableOption "shared programs.mcp.servers integration";

    # --- LSP servers ---
    lspServers = lib.mkOption {
      type = lib.types.attrsOf jsonFormat.type;
      default = {};
      description = "LSP server definitions for lsp-config.json.";
      example = lib.literalExpression ''
        {
          typescript = {
            command = "typescript-language-server";
            args = ["--stdio"];
            fileExtensions = {".ts" = "typescript";};
          };
        }
      '';
    };

    # --- Agents ---
    agents = hmHelpers.mkContentOption "Custom agent .md files for ~/.copilot/agents/.";
    agentsDir = hmHelpers.mkDirOption "Directory of agent .md files.";

    # --- Skills ---
    skills = hmHelpers.mkContentOption "Skill directories (SKILL.md) for ~/.copilot/skills/.";
    skillsDir = hmHelpers.mkDirOption "Directory of skill subdirectories.";

    # --- Instructions ---
    instructions = hmHelpers.mkContentOption "Instruction .md files for ~/.copilot/instructions/.";
    instructionsDir = hmHelpers.mkDirOption "Directory of instruction .md files.";

    # --- Environment variables ---
    environmentVariables = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = ''
        Extra environment variables exported when launching copilot CLI.
      '';
      example = lib.literalExpression ''
        {
          COPILOT_AUTO_UPDATE = "false";
          COPILOT_MODEL = "claude-sonnet-4";
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      (map (hmHelpers.mkExclusiveAssertion "copilot-cli" cfg) exclusiveInlineDirNames)
      ++ [
        {
          assertion =
            (allMcpServers == {} && cfg.lspServers == {})
            || cfg.package != null;
          message = "`programs.copilot-cli.package` cannot be null when `mcpServers`, `lspServers`, or `enableMcpIntegration` is configured.";
        }
      ];

    home = {
      activation.copilotCliSettings =
        lib.mkIf (filteredSettings != {})
        (lib.hm.dag.entryAfter ["writeBoundary"] settingsActivationScript);

      file =
        # LSP config (immutable, symlink)
        lib.optionalAttrs (cfg.lspServers != {}) {
          "${cfg.configDir}/lsp-config.json".source =
            jsonFormat.generate "copilot-lsp-config.json" cfg.lspServers;
        }
        # Inline agents
        // hmHelpers.mkMarkdownEntries cfg.configDir "agents" cfg.agents
        // lib.optionalAttrs (cfg.agentsDir != null) {
          "${cfg.configDir}/agents" = {
            source = cfg.agentsDir;
            recursive = true;
          };
        }
        # Inline skills
        // hmHelpers.mkSkillEntries cfg.configDir cfg.skills
        // lib.optionalAttrs (cfg.skillsDir != null) {
          "${cfg.configDir}/skills" = {
            source = cfg.skillsDir;
            recursive = true;
          };
        }
        # Inline instructions
        // hmHelpers.mkMarkdownEntries cfg.configDir "instructions" cfg.instructions
        // lib.optionalAttrs (cfg.instructionsDir != null) {
          "${cfg.configDir}/instructions" = {
            source = cfg.instructionsDir;
            recursive = true;
          };
        };

      # Package installation with optional wrapper
      packages = lib.optionals (cfg.package != null) [
        (
          if wrapperArgs != [] || cfg.environmentVariables != {}
          then
            pkgs.symlinkJoin {
              name = "copilot-cli-wrapped";
              paths = [cfg.package];
              postBuild = let
                envExports =
                  lib.concatStringsSep "\n"
                  (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}")
                    cfg.environmentVariables);
              in ''
                mv $out/bin/copilot $out/bin/.copilot-wrapped
                cat > $out/bin/copilot << 'WRAPPER'
                #!${pkgs.bash}/bin/bash
                ${envExports}
                exec -a "$0" "$out/bin/.copilot-wrapped" ${lib.escapeShellArgs wrapperArgs} "$@"
                WRAPPER
                chmod +x $out/bin/copilot
              '';
            }
          else cfg.package
        )
      ];
    };
  };
}
