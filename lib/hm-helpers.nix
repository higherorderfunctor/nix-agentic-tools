# Shared helpers for AI CLI modules (copilot-cli, kiro-cli, devenv).
#
# Provides content option builders, MCP server transformation, settings
# utilities, and file generation helpers.
{lib}: let
  aiCommon = import ./ai-common.nix {inherit lib;};
in rec {
  # ── Settings utilities ──────────────────────────────────────────────

  # Delegated to lib/ai-common.nix (single source of truth).
  inherit (aiCommon) filterNulls;

  # ── Option builders ──────────────────────────────────────────────────

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

  # ── File entry builders ──────────────────────────────────────────────

  mkSourceEntry = content:
    if lib.isPath content
    then {source = content;}
    else {text = content;};

  mkMarkdownEntries = configDir: subdir: attrs:
    lib.mapAttrs' (name: content:
      lib.nameValuePair "${configDir}/${subdir}/${name}.md"
      (mkSourceEntry content))
    attrs;

  mkSkillEntries = configDir: attrs:
    lib.mapAttrs' (name: content:
      if lib.isPath content && lib.pathIsDirectory content
      then
        lib.nameValuePair "${configDir}/skills/${name}" {
          source = content;
          recursive = true;
        }
      else
        lib.nameValuePair "${configDir}/skills/${name}/SKILL.md"
        (mkSourceEntry content))
    attrs;

  # ── MCP server transformation ───────────────────────────────────────

  mkMcpServer = server:
    (removeAttrs server ["disabled"])
    // (lib.optionalAttrs (server ? url) {type = "http";})
    // (lib.optionalAttrs (server ? command) {type = "stdio";})
    // {enabled = !(server.disabled or false);};

  # ── Assertion builder ────────────────────────────────────────────────

  # moduleName: e.g. "copilot-cli" or "kiro-cli"
  mkExclusiveAssertion = moduleName: cfg: name: {
    assertion = !(cfg.${name} != {} && cfg.${name + "Dir"} != null);
    message = "Cannot specify both `programs.${moduleName}.${name}` and `programs.${moduleName}.${name}Dir`.";
  };

  # ── Settings activation script ───────────────────────────────────────
  # Generates a shell snippet that merges Nix-declared settings into
  # an existing mutable JSON config file on activation.
  #
  # configDir: relative path from $HOME (e.g. ".copilot")
  # configFile: relative path from configDir (e.g. "config.json" or "settings/cli.json")
  # nixSettingsPath: Nix store path to the generated settings JSON
  # jq: path to jq binary
  mkSettingsActivationScript = {
    configFile,
    nixSettingsPath,
    jq,
    ...
  }: let
    parentDir = builtins.dirOf configFile;
  in ''
    TARGET_DIR="$HOME/${parentDir}"
    CONFIG_FILE="$HOME/${configFile}"
    mkdir -p "$TARGET_DIR"
    if [ -f "$CONFIG_FILE" ]; then
      ${jq} -s '.[0] * .[1]' "$CONFIG_FILE" "${nixSettingsPath}" > "$CONFIG_FILE.tmp"
      mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    else
      cp "${nixSettingsPath}" "$CONFIG_FILE"
      chmod 644 "$CONFIG_FILE"
    fi
  '';
}
