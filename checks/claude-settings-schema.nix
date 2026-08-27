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
  aiCommon = import ../lib/ai/ai-common.nix {inherit lib;};

  evalSurface = def:
    (lib.evalModules {
      modules = [
        {
          options.nativeSettings = lib.mkOption {
            type = lib.types.submodule {
              freeformType = (pkgs.formats.json {}).type;
              inherit (surface) options;
            };
            default = {};
          };
        }
        {nativeSettings = def;}
      ];
    })
    .config
    .nativeSettings;

  # `deepSeq` because the module system is lazy: a bad value buried in an
  # unforced attribute would otherwise "pass" by never being looked at.
  verdictOf = def: let
    attempt = builtins.tryEval (builtins.deepSeq (evalSurface def) "accepted");
  in
    if attempt.success
    then attempt.value
    else "rejected";

  renderedOf = def: builtins.toJSON (aiCommon.filterNulls (evalSurface def));

  behaviorCases = [
    {
      name = "an unset config still renders nothing";
      actual = renderedOf {};
      expected = "{}";
      remedy = ''
        Every generated option defaults to null and `filterNulls` is what keeps
        those out of settings.json. If this renders anything, the new surface
        MATERIALIZES keys the user never set — a behavior change for every
        consumer on upgrade, and the single thing this whole generator is not
        allowed to do.
      '';
    }
    {
      name = "only what was set survives, nested";
      actual = renderedOf {permissions.defaultMode = "manual";};
      expected = ''{"permissions":{"defaultMode":"manual"}}'';
      remedy = ''
        Null siblings leaked into a nested record, or `filterNulls` stopped
        recursing / stopped dropping emptied sub-attrsets.
      '';
    }
    {
      name = "a closed value set on a HAND-AUTHORED option still rejects";
      actual = verdictOf {tui = "nonsense";};
      expected = "rejected";
      remedy = ''
        `tui` is hand-authored, so the generator stands down for it. If this
        accepts, the hand declaration lost its enum, or its `externalPaths`
        entry stood the generator down without anything taking over — which is
        precisely the harness bug described above, now in the real surface.
      '';
    }
    {
      name = "a closed value set on a GENERATED option rejects";
      actual = verdictOf {permissions.defaultMode = "bogus";};
      expected = "rejected";
      remedy = ''
        A generated enum degraded to a plain string. Check whether the node
        gained a wildcard sibling (see `mixedWildcard`) or whether the enum
        branch stopped firing for its type.
      '';
    }
    {
      name = "a declared scalar type rejects the wrong shape";
      actual = verdictOf {cleanupPeriodDays = "thirty";};
      expected = "rejected";
      remedy = "A generated scalar lost its type and fell through to freeform.";
    }
    {
      name = "an alias outside the enum literal is still accepted";
      actual = verdictOf {permissions.defaultMode = "manual";};
      expected = "accepted";
      remedy = ''
        `manual` is legal input that the binary rewrites, and it is NOT in the
        enum literal — the census widens the set by resolving the wrapper. If
        this rejects, that widening regressed and Nix now refuses a value the
        product accepts.
      '';
    }
    {
      name = "an unrecognized key is still settable (catch-all stays open)";
      actual = verdictOf {someKeyUpstreamHasNotShippedYet = true;};
      expected = "accepted";
      remedy = ''
        The freeform catch-all is deliberate: a brand-new upstream setting must
        be usable the day it ships, before this pin advances. Typos are caught
        by the unrecognized-key assertions in mkClaude.nix, not by closing this.
      '';
    }
  ];

  behaviorFailures =
    lib.filter (case: case.actual != case.expected) behaviorCases;

  describeBehavior = case: ''
    composed-surface case failed: ${case.name}

      expected: ${case.expected}
      actual:   ${case.actual}

    ${case.remedy}'';

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
    ++ map describeSnapshot snapshotFailures
    ++ map describeBehavior behaviorFailures;
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
        echo "ok — ${toString (builtins.length (lib.attrNames surface.options))} nativeSettings options, no stale or shadowed exception-table rows, ${toString (builtins.length behaviorCases)} composed-surface cases green" > $out
      '';
}
