# programs.copilot-cli home-manager module.
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

  # Merge Nix-declared settings into existing mutable config.json on activation.
  # Preserves runtime-mutated keys (trusted_folders, etc.).
  settingsActivationScript = let
    nixSettings = jsonFormat.generate "copilot-cli-settings.json" cfg.settings;
  in ''
    COPILOT_DIR="${cfg.configDir}"
    CONFIG_FILE="$COPILOT_DIR/config.json"
    mkdir -p "$COPILOT_DIR"
    if [ -f "$CONFIG_FILE" ]; then
      ${pkgs.jq}/bin/jq -s '.[0] * .[1]' "$CONFIG_FILE" "${nixSettings}" > "$CONFIG_FILE.tmp"
      mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    else
      cp "${nixSettings}" "$CONFIG_FILE"
      chmod 644 "$CONFIG_FILE"
    fi
  '';

  # Content option helpers (matching upstream claude-code patterns)
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

  # MCP server transformation (from programs.mcp.servers)
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

  # Wrapper args for MCP injection
  wrapperArgs =
    lib.optionals (allMcpServers != {}) [
      "--additional-mcp-config"
      "${jsonFormat.generate "copilot-mcp-config.json" {mcpServers = allMcpServers;}}"
    ];

  # File generation
  mkMarkdownEntries = subdir: attrs:
    lib.mapAttrs' (name: content:
      lib.nameValuePair "${cfg.configDir}/${subdir}/${name}.md"
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

  exclusiveInlineDirNames = ["agents" "instructions" "skills"];

  mkExclusiveAssertion = name: {
    assertion = !(cfg.${name} != {} && cfg.${name + "Dir"} != null);
    message = "Cannot specify both `programs.copilot-cli.${name}` and `programs.copilot-cli.${name}Dir`.";
  };
in {
  options.programs.copilot-cli = {
    # --- Core ---
    enable = lib.mkEnableOption "GitHub Copilot CLI";

    package = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = pkgs.copilot-cli or null;
      defaultText = lib.literalExpression "pkgs.copilot-cli";
      description = "The copilot-cli package to install.";
    };

    configDir = lib.mkOption {
      type = lib.types.str;
      default = ".copilot";
      description = "Config directory relative to HOME. Override via COPILOT_HOME.";
    };

    # --- Settings (activation merge into config.json) ---
    settings = lib.mkOption {
      inherit (jsonFormat) type;
      default = {};
      description = ''
        JSON settings merged into ~/.copilot/config.json on activation.
        Runtime-mutated keys (trusted_folders, etc.) are preserved.
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
    agents = mkContentOption "Custom agent .md files for ~/.copilot/agents/.";
    agentsDir = mkDirOption "Directory of agent .md files.";

    # --- Skills ---
    skills = mkContentOption "Skill directories (SKILL.md) for ~/.copilot/skills/.";
    skillsDir = mkDirOption "Directory of skill subdirectories.";

    # --- Instructions ---
    instructions = mkContentOption "Instruction .md files for ~/.copilot/instructions/.";
    instructionsDir = mkDirOption "Directory of instruction .md files.";

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
      (map mkExclusiveAssertion exclusiveInlineDirNames)
      ++ [
        {
          assertion = (allMcpServers == {} && cfg.lspServers == {})
            || cfg.package != null;
          message = "`programs.copilot-cli.package` cannot be null when `mcpServers`, `lspServers`, or `enableMcpIntegration` is configured.";
        }
      ];

    home = {
      activation.copilotCliSettings = lib.mkIf (cfg.settings != {})
        (lib.hm.dag.entryAfter ["writeBoundary"] settingsActivationScript);

      file =
        # LSP config (immutable, symlink)
        lib.optionalAttrs (cfg.lspServers != {}) {
          "${cfg.configDir}/lsp-config.json".source =
            jsonFormat.generate "copilot-lsp-config.json" cfg.lspServers;
        }
        # Inline agents
        // mkMarkdownEntries "agents" cfg.agents
        // lib.optionalAttrs (cfg.agentsDir != null) {
          "${cfg.configDir}/agents" = {
            source = cfg.agentsDir;
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
        # Inline instructions
        // mkMarkdownEntries "instructions" cfg.instructions
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
                envExports = lib.concatStringsSep "\n"
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
