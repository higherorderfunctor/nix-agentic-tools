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

  # Accepts both Nix path literals and absolute string paths for
  # the directory case (via `builtins.readFileType`). Guarding on
  # `lib.isPath` alone would short-circuit string-interpolated
  # paths like `"${pkg}/share/skill"` to the file fallback, which
  # uses `mkSourceEntry` and writes the path text as SKILL.md
  # content — matching the upstream HM `mkSkillEntry` bug.
  mkSkillEntries = configDir: attrs:
    lib.mapAttrs' (name: content:
      if
        (builtins.isPath content || builtins.isString content)
        && (builtins.readFileType content) == "directory"
      then
        lib.nameValuePair "${configDir}/skills/${name}" {
          source = content;
          recursive = true;
        }
      else
        lib.nameValuePair "${configDir}/skills/${name}/SKILL.md"
        (mkSourceEntry content))
    attrs;

  # Recursively enumerate a skill source directory at eval time
  # and emit devenv-compatible
  # `files."<prefix>/<relpath>".source = <file>;` entries for
  # every leaf file. Mirrors HM `recursive = true` in user space
  # because devenv's `files.<name>.source = path` option only
  # creates a single dir symlink (Layout A) and has no recursive
  # walk of its own.
  #
  # Accepts both Nix path literals (e.g. `./path/to/skill`) and
  # absolute string paths (e.g. `"${pkg}/share/skill"`) — uses
  # `builtins.readFileType` which is type-agnostic.
  #
  # Usage:
  #   mkDevenvSkillEntries ".claude" { skillName = ./path/to/skill; }
  # Returns:
  #   {
  #     ".claude/skills/skillName/SKILL.md".source =
  #       ./path/to/skill/SKILL.md;
  #     ".claude/skills/skillName/supporting.md".source =
  #       ./path/to/skill/supporting.md;
  #     ...
  #   }
  #
  # Nested subdirectories inside a skill dir are preserved in the
  # resulting path keys (e.g.
  # `.claude/skills/foo/references/bar.md`).
  #
  # For single-file skills (path points to a regular file, not a
  # dir), falls back to a single
  # `{configDir}/skills/{name}/SKILL.md` entry mirroring how
  # `mkSkillEntries` handles the same case.
  mkDevenvSkillEntries = configDir: attrs: let
    walkDir = prefix: dir:
      lib.concatMapAttrs (
        name: kind:
          if kind == "directory"
          then walkDir "${prefix}/${name}" (dir + "/${name}")
          else if kind == "regular" || kind == "symlink"
          then {"${prefix}/${name}".source = dir + "/${name}";}
          else {} # skip unknown entries
      )
      (builtins.readDir dir);
  in
    lib.concatMapAttrs (
      skillName: skillPath:
      # `builtins.readFileType` accepts both Nix paths and
      # absolute string paths, so this handles skill sources
      # from both `./rel/path` literals and `"${pkg}/share"`
      # interpolation results uniformly.
        if (builtins.readFileType skillPath) == "directory"
        then walkDir "${configDir}/skills/${skillName}" skillPath
        else {"${configDir}/skills/${skillName}/SKILL.md".source = skillPath;}
    )
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
  # Shell snippet that merges Nix-declared JSON settings into an existing
  # mutable JSON config file at HM activation time. The settings JSON is
  # INLINED via a quoted heredoc (not a store-path read) so module-eval
  # tests can assert on rendered content and the merge stays atomic.
  # `jq -s '.[0] * .[1]'` makes Nix-declared values win on key conflict
  # while preserving runtime-added keys (oauth tokens in ~/.claude.json,
  # trusted_folders in copilot settings.json, etc.).
  #
  # configFile:   path relative to $HOME (".copilot/settings.json",
  #               ".kiro/settings/cli.json", ".claude.json").
  # settingsJson: JSON string to merge (caller `builtins.toJSON`'s it;
  #               Kiro flattens dot-keys first).
  # jq:           absolute jq binary path ("${pkgs.jq}/bin/jq").
  # coreutils:    coreutils package (absolute paths for every command).
  mkSettingsActivationScript = {
    configFile,
    settingsJson,
    jq,
    coreutils,
  }: let
    parentDir = builtins.dirOf configFile;
  in ''
    set -eu
    TARGET_DIR="$HOME/${parentDir}"
    CONFIG_FILE="$HOME/${configFile}"
    ${coreutils}/bin/mkdir -p "$TARGET_DIR"
    NIX_SETTINGS=$(${coreutils}/bin/mktemp)
    ${coreutils}/bin/cat > "$NIX_SETTINGS" <<'NAT_SETTINGS_EOF'
    ${settingsJson}
    NAT_SETTINGS_EOF
    if [ ! -f "$CONFIG_FILE" ]; then
      ${coreutils}/bin/cp "$NIX_SETTINGS" "$CONFIG_FILE"
    else
      TMP=$(${coreutils}/bin/mktemp)
      ${jq} -s '.[0] * .[1]' "$CONFIG_FILE" "$NIX_SETTINGS" > "$TMP"
      ${coreutils}/bin/mv "$TMP" "$CONFIG_FILE"
    fi
    ${coreutils}/bin/rm -f "$NIX_SETTINGS"
    ${coreutils}/bin/chmod 644 "$CONFIG_FILE"
  '';
}
