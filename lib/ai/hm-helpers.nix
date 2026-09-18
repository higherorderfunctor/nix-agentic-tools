# Shared helpers for AI CLI modules (copilot-cli, kiro-cli, devenv).
#
# Provides content option builders, MCP server transformation, settings
# utilities, and file generation helpers.
{lib}: let
  aiCommon = import ./ai-common.nix {inherit lib;};
  own = import ./own.nix {inherit lib;};

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

  # ── Owned artifacts ──────────────────────────────────────────────────

  # Emit one `own` bundle AND the eval-visible record of its plan, from one
  # set of arguments. Every `own` caller in this repo goes through here.
  #
  # `own` ships content as data in a store-resident plan, so the emitted body
  # names neither the document it reconciles nor the bytes it will write, and
  # the plan file itself cannot be read back at eval: importing a derivation is
  # forbidden here, and discarding the plan's string context to make it
  # readable would drop the store references that keep a rendered command alive
  # in the generation's closure. `ai.<runtime>._ownPlans.<write entry>` is
  # therefore the ONLY eval-visible record of what a writer will do, and it
  # carries `own`'s own plan value rather than a caller-side mirror of it.
  #
  # `declared` is the one thing the plan cannot carry: a document target's
  # content is `builtins.toJSON value`, and `builtins.fromJSON` REFUSES a
  # string that refers to a store path, so a check cannot recover the value
  # from the plan. It is keyed by the same document path the target names.
  #
  # runtime: ai.<runtime> namespace that records the plan.
  mkOwnBundle = {
    backend,
    declared ? {},
    runtime,
    ...
  } @ args: let
    owned = own (builtins.removeAttrs args ["declared" "runtime"]);
    # The record is reached through a NESTED value, never merged into `owned`
    # with `//` and never behind a `cfg`-derived attribute NAME. `own`
    # validates its plan eagerly under `builtins.seq`, and the module system
    # walks a fragment's key structure while it is still collecting the very
    # definitions a `cfg.configDir`-derived `ledger` or `path` reads — forcing
    # the validation there is an infinite recursion, which is what a caller
    # that merged the bundle with `//` got. Only attribute VALUES may reach
    # into `owned`.
    record = {
      ai.${runtime}._ownPlans.${args.entryNames.write} = {
        inherit declared;
        # As lazy as an assignment: the source is one shared thunk that
        # nothing forces until an attribute is demanded.
        inherit (owned) plan;
      };
    };
  in
    if backend == "hm"
    then record // {home.activation = owned.config.home.activation;}
    else
      record
      // {inherit (owned.config) enterTest tasks;};

  # Reconcile the Nix-owned leaves of ONE runtime-writable document, keeping
  # every unowned sibling. The prior generation's ledger retires leaves this
  # one no longer declares; an empty declaration is therefore a retirement and
  # NOT a reason to skip the writer.
  #
  # codec:   "json", or "toml" for a document with native comments to keep.
  # entry:   home.activation attribute name — a consumer ordering contract.
  # ledger:  "{json,toml}-settings/<name>.json" relative to the state root; a
  #          LITERAL at the call site, because a derived one silently orphans
  #          every ownership record the previous name wrote.
  # path:    document path relative to $HOME.
  # python:  pkgs.python3, or one carrying tomlkit for codec = "toml".
  # runtime: ai.<runtime> namespace that records the declaration.
  # value:   the leaves this generation owns (Kiro flattens dot-keys first).
  mkOwnedDocument = {
    codec ? "json",
    entry,
    ledger,
    path,
    pkgs,
    python,
    runtime,
    value,
  }:
    mkOwnBundle {
      backend = "hm";
      declared.${path} = value;
      entryNames.write = entry;
      targets = [
        {
          inherit codec ledger path;
          units.text = builtins.toJSON value;
        }
      ];
      inherit pkgs python runtime;
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
  # reconciler:   shared reconcile-toml.py source path.
  # renderCommand: optional runtime JSON renderer, instead of settingsJson.
  # settingsJson: inlined JSON declaration.
  # stateName:    safe, stable name unique to the destination config file.
  # stateRoot:    trusted shell expression; defaults to XDG state/HOME fallback.
  #
  # New files are private (0600); existing regular-file permissions survive.
  #
  # ONE caller is left: kiro's `mcp.json`, which needs a runtime renderer and
  # the devenv roots. Everything that declares its leaves at eval time now goes
  # through `mkOwnedDocument` above. The `toml` alias is gone with codex, which
  # was its only caller; `mkReconcileSettingsActivationScript` keeps its
  # `format` parameter because reconcile-toml.py still takes `--format` and
  # Home Manager ROLLBACK runs an older generation's script, `--format toml`
  # and all, against today's ledgers.
  mkSettingsActivationScript = mkReconcileSettingsActivationScript "json";

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
