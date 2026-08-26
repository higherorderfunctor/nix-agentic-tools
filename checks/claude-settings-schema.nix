# Exception-table rot guard for the generated `ai.claude.nativeSettings`
# option surface.
#
# Most of that surface is DERIVED: `generateSettingsOptions.nix` walks the
# settings schema the packaged binary emits about itself and declares one typed
# option per path. The parts that are NOT derived are two small hand tables —
# `overrideTable` and the hand-authored declarations in `nativeSettingsOptions.nix`
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
# `collisions` and `mixedWildcard` are SNAPSHOTS rather than emptiness
# assertions, because neither is a defect on its own:
#
#   * `collisions` is just the hand-authored key set. Pinning it means a key
#     that upstream has since typed properly — so the hand row could be dropped
#     and taken from the schema instead — surfaces as a diff to look at, rather
#     than a hand row quietly outliving its reason.
#   * `mixedWildcard` is empty today and is the tell for a path-grammar
#     regression: a node the walk thinks carries both a `.*` wildcard and named
#     children degrades to `attrsOf freeformType` and loses its typing. That
#     happened once already — `hooks.*[]` parsed as a named child called `*` —
#     and it was reported, not thrown, so nothing failed. Pinning the list is
#     what turns the report into a gate.
#
# Eval-only: readFile plus a module-system walk. No IFD, no derivation built,
# and no ~390 MB claude-code binary.
{
  lib,
  pkgs,
}: let
  extracted =
    builtins.fromJSON (builtins.readFile ../overlays/claude-code-extracted.json);
  # The sidecar carries no version of its own; the sources file is what the
  # extraction was run against.
  claudeVersion =
    (builtins.fromJSON (builtins.readFile ../overlays/claude-code-sources.json)).version;
  surface = import ../packages/claude-code/lib/nativeSettingsOptions.nix {
    inherit extracted lib pkgs;
  };
  inherit (surface) report;

  # SNAPSHOT — the hand-authored declarations in nativeSettingsOptions.nix.
  # Update this list in the same commit as that attrset.
  expectedCollisions = [
    "attribution"
    "effortLevel"
    "enableWorkflows"
    "model"
    "tui"
    "workflowKeywordTriggerEnabled"
  ];

  # SNAPSHOT — see the header. Empty is the healthy value; a non-empty one is a
  # grammar regression, not a fact about upstream.
  expectedMixedWildcard = [];

  renderList = xs:
    if xs == []
    then "    (none)"
    else lib.concatMapStringsSep "\n" (x: "    - ${x}") xs;

  # Each entry: a field that must be empty, and what a non-empty one means.
  emptinessRules = [
    {
      field = "staleOverrides";
      remedy = ''
        A row in `overrideTable` (packages/claude-code/lib/generateSettingsOptions.nix)
        names a path the packaged binary no longer emits, so it applies to
        nothing. Delete the row, or re-point it at the key upstream renamed to.
      '';
    }
    {
      field = "staleExternalPaths";
      remedy = ''
        A hand-authored declaration in
        packages/claude-code/lib/nativeSettingsOptions.nix names a key the
        packaged binary no longer declares. The option still exists and still
        writes into settings.json, where Claude now ignores it silently.
        Delete the declaration, or re-point it.
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
      field = "missingPaths";
      remedy = ''
        The sidecar lists these as public top-level settings keys but carries
        no `settings.paths` entry describing them, so no option could be
        generated. That is an EXTRACTOR defect (overlays/claude-code/census.mjs),
        not a table one — the schema walk lost a subtree.
      '';
    }
  ];

  emptinessFailures =
    lib.filter (rule: report.${rule.field} != []) emptinessRules;

  snapshotRules = [
    {
      field = "collisions";
      expected = expectedCollisions;
      remedy = ''
        This is the hand-authored declaration set in
        packages/claude-code/lib/nativeSettingsOptions.nix. If you added or
        removed one deliberately, update `expectedCollisions` in this file in
        the same commit. If you did not, the packaged binary changed which keys
        it declares underneath a hand row.
      '';
    }
    {
      field = "mixedWildcard";
      expected = expectedMixedWildcard;
      remedy = ''
        A node carrying BOTH a `.*` wildcard and named children cannot be an
        `attrsOf`, so it degraded to `attrsOf <freeform>` and lost its typing.
        Either the sidecar's path grammar grew a spelling `parseSegment` in
        packages/claude-code/lib/generateSettingsOptions.nix does not handle
        (this is what `hooks.*[]` did), or the binary genuinely gained such a
        node. Fix the parser, or update `expectedMixedWildcard` here.
      '';
    }
  ];

  snapshotFailures =
    lib.filter (rule: report.${rule.field} != rule.expected) snapshotRules;

  describeEmptiness = rule: ''
    report.${rule.field} is not empty:

    ${renderList report.${rule.field}}

    ${rule.remedy}'';

  describeSnapshot = rule: ''
    report.${rule.field} does not match its snapshot.

      expected:
    ${renderList rule.expected}

      actual:
    ${renderList report.${rule.field}}

    ${rule.remedy}'';

  failures =
    map describeEmptiness emptinessFailures
    ++ map describeSnapshot snapshotFailures;
in {
  claude-settings-schema =
    if failures != []
    then
      throw ''
        claude settings-schema guard: ${toString (builtins.length failures)} finding(s)
        against overlays/claude-code-extracted.json (claude-code ${claudeVersion}).

        ${lib.concatStringsSep "\n\n" failures}
      ''
    else
      pkgs.runCommandLocal "claude-settings-schema-check" {} ''
        echo "ok — ${toString (builtins.length (lib.attrNames surface.options))} nativeSettings options, no stale or shadowed exception-table rows" > $out
      '';
}
