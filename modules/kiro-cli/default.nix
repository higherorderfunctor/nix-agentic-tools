# ============================================================================
# REFERENCE ONLY — PRE-FACTORY KIRO-CLI HM MODULE.
#
# This file is NOT imported by any flake output. It is kept in the tree
# solely as source material for the kiro absorption work tracked in
# `docs/plan.md` "Ideal architecture gate → Absorption backlog".
#
# Target: absorb into `packages/kiro-cli/lib/mkKiro.nix` as the
# config callback body. The current mkKiro.nix has an empty
# `config = _: {}` — the settings/mcp.json / steering / skills /
# agents / hooks merge logic below needs to be ported there, writing
# to `home.file.*` (HM) or `files.*` (devenv) via the mkAiApp backend
# dispatch (another backlog item).
#
# Do NOT implement `programs.kiro-cli.*` as a target for fanout —
# the factory architecture replaces that upstream-style delegation
# with direct file writes from the factory config callback.
# ============================================================================
#
# programs.kiro-cli home-manager module (legacy).
# Mirrors upstream programs.claude-code conventions.
#
# Config directory: ~/.kiro/
# Mutable at runtime: settings/cli.json (model, toggles)
# Immutable (Nix-managed): settings/mcp.json, steering/, skills/, agents/, hooks/
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.kiro-cli;
  jsonFormat = pkgs.formats.json {};
  hmHelpers = import ../../lib/hm-helpers.nix {inherit lib;};

  filteredSettings = hmHelpers.filterNulls cfg.settings;

  # Merge Nix-declared settings into existing mutable cli.json on activation.
  # Preserves runtime-mutated keys.
  settingsActivationScript = hmHelpers.mkSettingsActivationScript {
    inherit (cfg) configDir;
    configFile = "${cfg.configDir}/settings/cli.json";
    nixSettingsPath = jsonFormat.generate "kiro-cli-settings.json" filteredSettings;
    jq = "${pkgs.jq}/bin/jq";
  };

  # MCP server transformation
  transformedMcpServers =
    lib.optionalAttrs
    (cfg.enableMcpIntegration && config.programs.mcp.enable or false)
    (lib.mapAttrs (_: hmHelpers.mkMcpServer) config.programs.mcp.servers);

  allMcpServers = transformedMcpServers // cfg.mcpServers;

  # Kiro-specific: JSON entry generation for agents and hooks
  mkJsonEntries = subdir: attrs:
    lib.mapAttrs' (name: content:
      lib.nameValuePair "${cfg.configDir}/${subdir}/${name}.json"
      (hmHelpers.mkSourceEntry content))
    attrs;

  exclusiveInlineDirNames = ["agents" "hooks" "skills" "steering"];
in {
  options.programs.kiro-cli = {
    # --- Core ---
    enable = lib.mkEnableOption "Kiro CLI";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = pkgs.kiro-cli or null;
      defaultText = lib.literalExpression "pkgs.kiro-cli";
      description = "The kiro-cli package to install.";
    };

    configDir = lib.mkOption {
      type = lib.types.str;
      default = ".kiro";
      description = "Config directory relative to HOME.";
    };

    # --- Settings (activation merge into settings/cli.json) ---
    settings = lib.mkOption {
      type = lib.types.submodule {
        freeformType = jsonFormat.type;
        options = {
          chat = lib.mkOption {
            type = lib.types.submodule {
              freeformType = jsonFormat.type;
              options = {
                defaultModel = lib.mkOption {
                  type = lib.types.nullOr lib.types.str;
                  default = null;
                  description = "Default chat model.";
                };
                enableThinking = lib.mkOption {
                  type = lib.types.nullOr lib.types.bool;
                  default = null;
                  description = "Enable thinking/reasoning mode.";
                };
              };
            };
            default = {};
            description = "Chat-related settings.";
          };
          telemetry = lib.mkOption {
            type = lib.types.submodule {
              freeformType = jsonFormat.type;
              options = {
                enabled = lib.mkOption {
                  type = lib.types.nullOr lib.types.bool;
                  default = null;
                  description = "Enable telemetry reporting.";
                };
              };
            };
            default = {};
            description = "Telemetry settings.";
          };
        };
      };
      default = {};
      description = ''
        JSON settings merged into ~/.kiro/settings/cli.json on activation.
        Runtime-mutated keys are preserved.
        Known keys are typed; unknown keys are accepted via freeformType.
      '';
      example = lib.literalExpression ''
        {
          chat = {
            defaultModel = "claude-sonnet-4";
            enableThinking = true;
          };
          telemetry.enabled = false;
        }
      '';
    };

    # --- MCP servers ---
    mcpServers = lib.mkOption {
      type = lib.types.attrsOf jsonFormat.type;
      default = {};
      description = "MCP server definitions for ~/.kiro/settings/mcp.json.";
    };

    enableMcpIntegration = lib.mkEnableOption "shared programs.mcp.servers integration";

    # --- Steering ---
    steering = hmHelpers.mkContentOption ''
      Global steering .md files for ~/.kiro/steering/.
      Should include YAML frontmatter with inclusion mode (auto, always, manual, fileMatch).
    '';
    steeringDir = hmHelpers.mkDirOption "Directory of global steering .md files.";

    # --- Skills ---
    skills = hmHelpers.mkContentOption "Skill directories (SKILL.md) for ~/.kiro/skills/.";
    skillsDir = hmHelpers.mkDirOption "Directory of skill subdirectories.";

    # --- Agents (JSON, not markdown) ---
    agents = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
      default = {};
      description = "Global agent .json definition files for ~/.kiro/agents/.";
    };
    agentsDir = hmHelpers.mkDirOption "Directory of global agent .json files.";

    # --- LSP servers ---
    lspServers = lib.mkOption {
      type = lib.types.attrsOf jsonFormat.type;
      default = {};
      description = "LSP server definitions for ~/.kiro/settings/lsp.json.";
      example = lib.literalExpression ''
        {
          nix = {
            command = "nixd";
            args = [];
          };
        }
      '';
    };

    # --- Hooks (JSON) ---
    hooks = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
      default = {};
      description = "Global hook .json files for ~/.kiro/hooks/.";
    };
    hooksDir = hmHelpers.mkDirOption "Directory of global hook .json files.";

    # --- Environment variables ---
    environmentVariables = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      description = ''
        Extra environment variables for kiro-cli.
      '';
      example = lib.literalExpression ''
        {
          KIRO_LOG_LEVEL = "info";
        }
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions =
      (map (hmHelpers.mkExclusiveAssertion "kiro-cli" cfg) exclusiveInlineDirNames)
      ++ [
        {
          assertion = (allMcpServers == {}) || cfg.package != null;
          message = "`programs.kiro-cli.package` cannot be null when `mcpServers` or `enableMcpIntegration` is configured.";
        }
      ];

    home = {
      activation.kiroCliSettings =
        lib.mkIf (filteredSettings != {})
        (lib.hm.dag.entryAfter ["writeBoundary"] settingsActivationScript);

      file =
        # MCP config (immutable, symlink)
        lib.optionalAttrs (allMcpServers != {}) {
          "${cfg.configDir}/settings/mcp.json".source =
            jsonFormat.generate "kiro-mcp-config.json" {mcpServers = allMcpServers;};
        }
        # LSP config
        // lib.optionalAttrs (cfg.lspServers != {}) {
          "${cfg.configDir}/settings/lsp.json".source =
            jsonFormat.generate "kiro-lsp-config.json" cfg.lspServers;
        }
        # Inline steering
        // hmHelpers.mkMarkdownEntries cfg.configDir "steering" cfg.steering
        // lib.optionalAttrs (cfg.steeringDir != null) {
          "${cfg.configDir}/steering" = {
            source = cfg.steeringDir;
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
        # Inline agents (JSON)
        // mkJsonEntries "agents" cfg.agents
        // lib.optionalAttrs (cfg.agentsDir != null) {
          "${cfg.configDir}/agents" = {
            source = cfg.agentsDir;
            recursive = true;
          };
        }
        # Inline hooks (JSON)
        // mkJsonEntries "hooks" cfg.hooks
        // lib.optionalAttrs (cfg.hooksDir != null) {
          "${cfg.configDir}/hooks" = {
            source = cfg.hooksDir;
            recursive = true;
          };
        };

      # Package installation with optional wrapper
      packages = lib.optionals (cfg.package != null) [
        (
          if cfg.environmentVariables != {}
          then
            pkgs.symlinkJoin {
              name = "kiro-cli-wrapped";
              paths = [cfg.package];
              postBuild = let
                envExports =
                  lib.concatStringsSep "\n"
                  (lib.mapAttrsToList (k: v: "export ${k}=${lib.escapeShellArg v}")
                    cfg.environmentVariables);
              in ''
                mv $out/bin/kiro-cli $out/bin/.kiro-cli-wrapped
                cat > $out/bin/kiro-cli << 'WRAPPER'
                #!${pkgs.bash}/bin/bash
                ${envExports}
                exec -a "$0" "$out/bin/.kiro-cli-wrapped" "$@"
                WRAPPER
                chmod +x $out/bin/kiro-cli
              '';
            }
          else cfg.package
        )
      ];
    };
  };
}
