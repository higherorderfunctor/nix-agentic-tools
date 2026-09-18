# Shared helpers for AI CLI modules (copilot-cli, kiro-cli, devenv).
#
# Provides content option builders, MCP server transformation, settings
# utilities, and file generation helpers.
{lib}: let
  aiCommon = import ./ai-common.nix {inherit lib;};

  mkReconcileSettingsActivationScript = format: {
    configFile,
    configRoot ? "$HOME",
    python,
    reconciler,
    renderCommand ? null,
    settingsJson ? null,
    stateName,
    stateRoot ? "\${XDG_STATE_HOME:-$HOME/.local/state}",
  }:
    assert lib.assertMsg ((settingsJson == null) != (renderCommand == null))
    "settings activation: set exactly one of settingsJson or renderCommand";
    assert lib.assertMsg (builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" stateName != null)
    "settings activation: stateName must contain only alphanumeric, dot, underscore, or hyphen characters: '${stateName}'"; let
      prefix = "NAT_${lib.toUpper format}";
      input =
        if renderCommand == null
        then ''
          <<'${prefix}_SETTINGS_EOF'
          ${settingsJson}
          ${prefix}_SETTINGS_EOF
        ''
        else ''<<< "$NAT_SETTINGS_JSON"'';
    in
      aiCommon.scopedActivation ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :

        # Keep the ownership ledger outside the application's mutable config.
        # The TOML directory is a live migration contract: never rename it.
        NAT_SETTINGS_CONFIG="${configRoot}"/${lib.escapeShellArg configFile}
        NAT_SETTINGS_STATE_DIR="${stateRoot}/nix-agentic-tools/${format}-settings"
        NAT_SETTINGS_MANIFEST="$NAT_SETTINGS_STATE_DIR/${stateName}.json"

        ${lib.optionalString (renderCommand != null) ''
          # Finish rendering before starting the reconciler. A failed secret
          # helper must not publish partial JSON or advance ownership.
          NAT_SETTINGS_JSON="$(
            ${renderCommand}
          )"
        ''}
        ${python}/bin/python ${lib.escapeShellArg "${reconciler}"} \
          --format ${format} \
          --config "$NAT_SETTINGS_CONFIG" \
          --manifest "$NAT_SETTINGS_MANIFEST" ${input}
      '';
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

  # Codex discovers a skill when the skill directory itself is a symlink, but
  # not when Home Manager/devenv create a real directory containing symlinked
  # leaves. Keep this separate from mkSkillEntries: Claude, Copilot, Kimchi and
  # Kiro still need the composable recursive layout that helper provides.
  mkSkillDirectoryEntries = configDir: attrs:
    lib.mapAttrs' (name: content:
      assert lib.assertMsg ((builtins.readFileType content) == "directory")
      "mkSkillDirectoryEntries: skill '${name}' must resolve to a directory";
        lib.nameValuePair "${configDir}/skills/${name}" {
          source = content;
        })
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

  # ── Settings activation scripts ──────────────────────────────────────
  # Reconcile only Nix-owned leaves in mixed-authority, runtime-writable files.
  # The prior-generation manifest removes retired leaves, current declarations
  # reassert their values, and every unowned sibling survives. Always emit the
  # writer: empty settings retract previous ownership, while an empty first
  # generation leaves externally managed files untouched.
  #
  # configFile:   path relative to configRoot (e.g. ".copilot/settings.json").
  # configRoot:   trusted shell expression; defaults to $HOME.
  # python:       Python package; TOML needs tomlkit, JSON uses the stdlib.
  # reconciler:   shared reconcile-toml.py source path (both formats).
  # renderCommand: optional runtime JSON renderer, instead of settingsJson.
  # settingsJson: inlined JSON declaration (Kiro flattens dot-keys first).
  # stateName:    safe, stable name unique to the destination config file.
  # stateRoot:    trusted shell expression; defaults to XDG state/HOME fallback.
  #
  # New files are private (0600); existing regular-file permissions survive.
  # Static home.file ownership remains the default for wholly declarative files.
  mkSettingsActivationScript = mkReconcileSettingsActivationScript "json";
  mkTomlSettingsActivationScript = mkReconcileSettingsActivationScript "toml";

  # NOTE: Kiro hook files used to be written here by `mkHooksActivationScript`.
  # They now ride the shared strategy-driven materializer
  # (`lib/ai/materialize.nix`) because that helper's prune
  # (`rm -f "$HOOKS_DIR"/*.json`) lived INSIDE the caller's
  # `mkIf (hooks != {})` gate: taking the hook surface from N to zero never
  # emitted the entry, so the prune never ran and every previously written hook
  # kept firing forever. The hook materializer's per-file manifest prunes
  # unconditionally and claims only the files it wrote. Kiro steering now uses
  # the ordinary runtime-files symlink sink.
}
