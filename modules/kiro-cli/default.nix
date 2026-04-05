# programs.kiro-cli home-manager module.
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

  # Merge Nix-declared settings into existing mutable cli.json on activation.
  # Preserves runtime-mutated keys.
  settingsActivationScript = let
    nixSettings = jsonFormat.generate "kiro-cli-settings.json" cfg.settings;
  in ''
    KIRO_DIR="$HOME/${cfg.configDir}"
    SETTINGS_DIR="$KIRO_DIR/settings"
    CONFIG_FILE="$SETTINGS_DIR/cli.json"
    mkdir -p "$SETTINGS_DIR"
    if [ -f "$CONFIG_FILE" ]; then
      ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$CONFIG_FILE" "${nixSettings}" > "$CONFIG_FILE.tmp"
      mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    else
      cp "${nixSettings}" "$CONFIG_FILE"
      chmod 644 "$CONFIG_FILE"
    fi
  '';

  # Content option helpers
  mkContentOption = description:
    lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
      default = {};
      inherit description;
    };

  mkDirOption = description:
    lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      inherit description;
    };

  mkSourceEntry = content:
    if lib.isPath content
    then {source = content;}
    else {text = content;};

  # MCP server transformation
  mkMcpServer = server:
    (removeAttrs server ["disabled"])
    // (lib.optionalAttrs (server ? url) {type = "http";})
    // (lib.optionalAttrs (server ? command) {type = "stdio";})
    // {enabled = !(server.disabled or false);};

  transformedMcpServers =
    lib.optionalAttrs
    (cfg.enableMcpIntegration && config.programs.mcp.enable or false)
    (lib.mapAttrs (_: mkMcpServer) config.programs.mcp.servers);

  allMcpServers = transformedMcpServers // cfg.mcpServers;

  # File generation
  mkMarkdownEntries = subdir: attrs:
    lib.mapAttrs' (name: content:
      lib.nameValuePair "${cfg.configDir}/${subdir}/${name}.md"
      (mkSourceEntry content))
    attrs;

  mkJsonEntries = subdir: attrs:
    lib.mapAttrs' (name: content:
      lib.nameValuePair "${cfg.configDir}/${subdir}/${name}.json"
      (mkSourceEntry content))
    attrs;

  mkSkillEntries = attrs:
    lib.mapAttrs' (name: content:
      if lib.isPath content && lib.pathIsDirectory content
      then
        lib.nameValuePair "${cfg.configDir}/skills/${name}" {
          source = content;
          recursive = true;
        }
      else
        lib.nameValuePair "${cfg.configDir}/skills/${name}/SKILL.md"
        (mkSourceEntry content))
    attrs;

  exclusiveInlineDirNames = ["agents" "hooks" "skills" "steering"];

  mkExclusiveAssertion = name: {
    assertion = !(cfg.${name} != {} && cfg.${name + "Dir"} != null);
    message = "Cannot specify both `programs.kiro-cli.${name}` and `programs.kiro-cli.${name}Dir`.";
  };
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
      inherit (jsonFormat) type;
      default = {};
      description = ''
        JSON settings merged into ~/.kiro/settings/cli.json on activation.
        Runtime-mutated keys are preserved.
      '';
      example = lib.literalExpression ''
        {
          "chat.defaultModel" = "claude-sonnet-4";
          "chat.enableThinking" = true;
          "telemetry.enabled" = false;
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
    steering = mkContentOption ''
      Global steering .md files for ~/.kiro/steering/.
      Should include YAML frontmatter with inclusion mode (auto, always, manual, fileMatch).
    '';
    steeringDir = mkDirOption "Directory of global steering .md files.";

    # --- Skills ---
    skills = mkContentOption "Skill directories (SKILL.md) for ~/.kiro/skills/.";
    skillsDir = mkDirOption "Directory of skill subdirectories.";

    # --- Agents (JSON, not markdown) ---
    agents = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
      default = {};
      description = "Global agent .json definition files for ~/.kiro/agents/.";
    };
    agentsDir = mkDirOption "Directory of global agent .json files.";

    # --- Hooks (JSON) ---
    hooks = lib.mkOption {
      type = lib.types.attrsOf (lib.types.either lib.types.lines lib.types.path);
      default = {};
      description = "Global hook .json files for ~/.kiro/hooks/.";
    };
    hooksDir = mkDirOption "Directory of global hook .json files.";

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
      (map mkExclusiveAssertion exclusiveInlineDirNames)
      ++ [
        {
          assertion = (allMcpServers == {}) || cfg.package != null;
          message = "`programs.kiro-cli.package` cannot be null when `mcpServers` or `enableMcpIntegration` is configured.";
        }
      ];

    home = {
      activation.kiroCliSettings =
        lib.mkIf (cfg.settings != {})
        (lib.hm.dag.entryAfter ["writeBoundary"] settingsActivationScript);

      file =
        # MCP config (immutable, symlink)
        lib.optionalAttrs (allMcpServers != {}) {
          "${cfg.configDir}/settings/mcp.json".source =
            jsonFormat.generate "kiro-mcp-config.json" {mcpServers = allMcpServers;};
        }
        # Inline steering
        // mkMarkdownEntries "steering" cfg.steering
        // lib.optionalAttrs (cfg.steeringDir != null) {
          "${cfg.configDir}/steering" = {
            source = cfg.steeringDir;
            recursive = true;
          };
        }
        # Inline skills
        // mkSkillEntries cfg.skills
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
