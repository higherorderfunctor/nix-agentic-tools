# Exception-table rot guard for the generated `ai.claude.native.settings`
# option surface.
#
# Most of that surface is DERIVED: `generateSettingsOptions.nix` walks the
# settings schema the packaged binary emits about itself and declares one typed
# option per path. The parts that are NOT derived are two small hand tables —
# `overrideTable` and the hand-authored declarations in `nativeOptions.nix`
# — and a hand table's failure mode is silence. An override aimed at a key
# upstream renamed simply stops applying; a hand declaration for a key upstream
# dropped keeps offering an option that writes a setting Claude now ignores.
# Neither breaks an eval, so neither is visible without asking.
#
# So ask, on every claude-code bump, in the PR that caused it:
#
#   * `staleOverrides` / `staleExternalPaths` — a table row pointed at a path
#     the binary no longer emits. Delete the row (or fix the spelling).
#   * `shadowedOverrides` — a row in BOTH tables. `externalPaths` wins, so the
#     override row is dead code. Delete one side.
#   * `missingPaths` — a public top-level key the sidecar named but never
#     described, so the tree walk had nothing to build an option from. That is
#     an extractor bug, not a table bug.
#
# `mixedWildcard` is empty today and is the tell for a path-grammar
# regression: a node the walk thinks carries both a `.*` wildcard and named
# children degrades to `attrsOf freeformType` and loses its typing. That
# happened once already — `hooks.*[]` parsed as a named child called `*` —
# and it was reported, not thrown, so nothing failed. Requiring an empty list
# turns the report into a gate.
#
# Eval-only: readFile plus a module-system walk. No IFD, no derivation built,
# and no ~390 MB claude-code binary.
{
  harness,
  lib,
  pkgs,
  ...
}: {
  checks = let
    inherit (harness) checkRows rejectsChange;
    claudeFact = let
      extracted = import ../../../lib/extracted/facts.nix {inherit lib;};
    in
      extracted.get (extracted.load {dir = ../extracted;}).aggregate;
    # The sidecar carries no version of its own; the sources file is what the
    # extraction was run against.
    claudeVersion =
      (builtins.fromJSON (builtins.readFile ../sources.json)).version;
    surface = import ../lib/nativeOptions.nix {
      inherit claudeFact lib pkgs;
    };
    inherit (surface) report;

    # ── Composed-surface behavior ────────────────────────────────
    # The rules above interrogate the REPORT. These run real values through the
    # option surface a user actually gets — generated options and hand-authored
    # ones merged — because the two can disagree and the report cannot see it.
    #
    # This exists because a dev harness that exercised the generator in ISOLATION
    # reported a bad `tui` value as accepted. It was a harness artifact: it listed
    # `tui` among the paths the generator stands down for, without supplying the
    # hand declaration that was supposed to take over, so the value fell through
    # to the freeform type. The real surface rejects it. A test that can pass for
    # a reason unrelated to the thing it names is worse than no test, so the
    # assertion lives here against the composed surface instead.
    evalSurface = def:
      (lib.evalModules {
        modules = [
          {
            options.native.settings = lib.mkOption {
              type = lib.types.submodule {
                freeformType = (pkgs.formats.json {}).type;
                inherit (surface) options;
              };
              default = {};
            };
          }
          {native.settings = def;}
        ];
      })
    .config
    .native.settings;

    behaviorRows = {
      "generated cleanupPeriodDays must reject a string rather than degrade to freeform" = rejectsChange (def: (evalSurface def).cleanupPeriodDays) {
        valid.cleanupPeriodDays = 30;
        invalid.cleanupPeriodDays = "thirty";
        expected = 30;
      };
      # `manual` is a legal input the binary rewrites; it doubles as the
      # positive control for the generated enum.
      "generated permissions.defaultMode must accept manual but reject an unknown enum value" = rejectsChange (def: (evalSurface def).permissions.defaultMode) {
        valid.permissions.defaultMode = "manual";
        invalid.permissions.defaultMode = "bogus";
        expected = "manual";
      };
    };

    # Each entry: a field that must be empty, and what a non-empty one means.
    emptinessRules = [
      {
        field = "missingPaths";
        remedy = ''
          The sidecar lists these as public top-level settings keys but carries
          no `settings.paths` entry describing them, so no option could be
          generated. That is an EXTRACTOR defect (packages/claude-code/extract/census.mjs),
          not a table one — the schema walk lost a subtree.
        '';
      }
      {
        field = "mixedWildcard";
        remedy = ''
          A node carrying BOTH a `.*` wildcard and named children cannot be an
          `attrsOf`, so it degraded to `attrsOf <freeform>` and lost its typing.
          Either the sidecar's path grammar grew a spelling `parseSegment` in
          packages/claude-code/lib/generateSettingsOptions.nix does not handle
          (this is what `hooks.*[]` did), or the binary genuinely gained such a
          node. Fix the parser or model the node with an explicit typed option.
        '';
      }
      {
        field = "shadowedOverrides";
        remedy = ''
          A path is in BOTH hand tables: `overrideTable` and the hand-authored
          declarations. The hand declaration wins, so the override row is dead
          code that looks live. Delete one side — keeping both is how a future
          edit lands in the half that is not used.
        '';
      }
      {
        field = "staleExternalPaths";
        remedy = ''
          A hand-authored declaration in
          packages/claude-code/lib/nativeOptions.nix names a key the
          packaged binary no longer declares. The option still exists and still
          writes into settings.json, where Claude now ignores it silently.
          Delete the declaration, or re-point it.
        '';
      }
      {
        field = "staleOverrides";
        remedy = ''
          A row in `overrideTable` (packages/claude-code/lib/generateSettingsOptions.nix)
          names a path the packaged binary no longer emits, so it applies to
          nothing. Delete the row, or re-point it at the key upstream renamed to.
        '';
      }
    ];

    reportRows = builtins.listToAttrs (map (rule: {
        name = ''
          report.${rule.field} is not empty: ${lib.concatStringsSep ", " report.${rule.field}}
          ${rule.remedy}'';
        value = report.${rule.field} == [];
      })
      emptinessRules);
  in {
    claude-settings-schema = assert checkRows "Claude ${claudeVersion} settings schema report" reportRows;
    assert checkRows "Claude ${claudeVersion} composed settings" behaviorRows;
      pkgs.runCommandLocal "claude-settings-schema-check" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        echo "ok — ${toString (builtins.length (lib.attrNames surface.options))} native.settings options, no stale or shadowed exception-table rows, ${toString (builtins.length (lib.attrNames behaviorRows))} composed-surface cases green" > "$out"
      '';
  };
}
