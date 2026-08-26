# The `ai.claude.nativeSettings` option surface.
#
# Two sources, merged here and nowhere else:
#
#   1. MACHINE-DERIVED — `generateSettingsOptions.nix` walks the settings
#      schema the packaged binary emits about ITSELF (the drift-checked
#      `overlays/claude-code-extracted.json`, `.settings`) and declares a typed
#      `nullOr` option per path. Nothing here is hand-curated, so a key upstream
#      adds arrives with the next package bump instead of waiting for someone to
#      notice it.
#
#   2. HAND-AUTHORED — the short list below, for the places where the emitted
#      schema is not the option surface we want: a coercion (`attribution.*`
#      takes a bool), a soft enum the schema spells as a bare string (`model`),
#      or prose that carries operational knowledge the schema cannot
#      (`tui`'s read-only-store caveat, `ultracode`'s off-label status).
#
# Hand-authored declarations WIN. That is not a merge-order accident: their key
# set is handed to the generator as `externalPaths`, so the generator emits
# NOTHING for those paths and reports each one under `report.collisions`. A
# hand declaration can therefore never silently shadow a generated one, and a
# hand declaration aimed at a key the binary has since dropped surfaces as
# `report.staleExternalPaths` rather than sitting there rotting.
#
# `report` is exported for `checks/claude-settings-schema.nix`, which is what
# makes the exception tables above self-policing in CI rather than by review.
{
  lib,
  pkgs,
  extracted,
}: let
  gen = import ./generateSettingsOptions.nix {inherit lib;};

  freeformType = (pkgs.formats.json {}).type;

  # Non-retired model ids from the binary's own catalog.
  knownClaudeModels = extracted.models;

  # Keep this attrset SMALL. Every row is an exception to "the binary describes
  # itself", so each one is a standing maintenance cost — and the report field
  # `collisions` exists so a row that upstream has since typed properly shows up
  # as a diff in the bump PR.
  handAuthored = {
    attribution = lib.mkOption {
      type = lib.types.submodule {
        freeformType = (pkgs.formats.json {}).type;
        options = {
          commit = lib.mkOption {
            type =
              lib.types.coercedTo lib.types.bool
              (b:
                if b
                then null
                else "")
              (lib.types.nullOr lib.types.str);
            default = null;
            example = false;
            description = ''
              Attribution line Claude appends to commit messages
              it authors (settings.json `attribution.commit`).
              `true` (or null, the default) leaves Claude's own
              default text ("Generated with Claude Code"); `false`
              disables it (writes ""), dropping the generated /
              co-author trailer; a string sets custom text. Coerced
              to a nullOr-str at the type layer so it rides the
              shared filterNulls lowering unchanged.
            '';
          };
          pr = lib.mkOption {
            type =
              lib.types.coercedTo lib.types.bool
              (b:
                if b
                then null
                else "")
              (lib.types.nullOr lib.types.str);
            default = null;
            example = false;
            description = ''
              Attribution footer Claude appends to pull-request
              bodies (settings.json `attribution.pr`). Unlike
              `commit`, Claude's own upstream default for `pr` is
              already "" (pull-request attribution off), so here
              `true`/null (keep Claude's default) and `false`
              (write "" explicitly) coincide - both leave it
              disabled; a string enables it with custom footer
              text.
            '';
          };
        };
      };
      default = {};
      description = ''
        Commit / PR attribution (settings.json `attribution`).
        Each field accepts `true` (Claude's default), `false`
        (disabled - writes ""), or a literal string. Set
        `commit = false` to drop the co-author / "Generated with
        Claude Code" trailer.
      '';
    };
    effortLevel = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum extracted.effortLevels);
      default = null;
      description = ''
        Persisted Claude effort level. The valid set
        (low/medium/high/xhigh) is extracted from the packaged binary
        into overlays/claude-code-extracted.json. 'max' is session-only
        via /effort and cannot be persisted.
      '';
    };
    enableWorkflows = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = ''
        Master Workflows feature toggle — the /config "Dynamic
        workflows" setting. Enables the Workflow tool at all.
        null leaves Claude's own default (true). Mirrors a stable
        /config toggle; the key name is not in the official settings
        reference but has been stable across releases (verified on
        claude-code 2.1.202).
      '';
    };
    model = lib.mkOption {
      type =
        lib.types.nullOr
        (lib.types.either (lib.types.enum knownClaudeModels) lib.types.str);
      default = null;
      description = ''
        Claude model id. The ${toString (builtins.length knownClaudeModels)}
        non-retired ids in the packaged binary's model catalog
        (extracted into the drift-checked
        overlays/claude-code-extracted.json — never hand-curated) are
        ${lib.concatStringsSep ", " knownClaudeModels}. Any string is
        accepted (non-enforcing soft enum) — the binary's runtime model
        set is not a safe closed enum.
      '';
    };
    tui = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum ["default" "fullscreen"]);
      default = null;
      description = ''
        Terminal UI renderer — the persisted `/tui` setting.
        "fullscreen" is the flicker-free alt-screen renderer with
        virtualized scrollback (equivalent to env
        CLAUDE_CODE_NO_FLICKER=1); "default" is the classic
        main-screen renderer. null leaves Claude's own default.
        MUST be set here rather than via the interactive `/tui`
        command, which read-modify-writes settings.json and so fails
        against a read-only Nix store path. Verified on
        claude-code 2.1.206.
      '';
    };
    workflowKeywordTriggerEnabled = lib.mkOption {
      type = lib.types.nullOr lib.types.bool;
      default = null;
      description = ''
        Whether the "ultracode" keyword in a prompt opts THAT TURN
        into the Workflow tool (per-turn) — the /config "Ultracode
        keyword trigger" row. Orthogonal to the ultracode session
        mode. null leaves Claude's own default (true). Mirrors a
        stable /config toggle; the key name is not in the official
        settings reference but has been stable across releases
        (verified on claude-code 2.1.202). NOTE: the persisted key is
        `workflowKeywordTriggerEnabled`, not `ultracodeKeywordTrigger`
        (that string is only an in-memory UI alias).
      '';
    };
  };

  generated = gen.generate {
    # `or {}` degrades a sidecar predating settings extraction to "no generated
    # options" rather than an eval error; the freeform tail still accepts every
    # key, and `unrecognizedSettings.nix` has its own guard for that case.
    settings = extracted.settings or {};
    inherit freeformType;
    overrides = gen.overrideTable;
    # Derived, never restated: a hand-authored option and its `externalPaths`
    # entry cannot drift apart if the entry IS the option's name.
    externalPaths = lib.attrNames handAuthored;
  };
in {
  inherit (generated) report;
  # `//` is safe precisely because `externalPaths` already made it a disjoint
  # union — see the header.
  options = generated.options // handAuthored;
}
