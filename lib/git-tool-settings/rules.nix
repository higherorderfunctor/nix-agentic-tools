# The surface table every git tool shares: its sidecar's facts against its
# rows file (`packages/<owner>/extract/annotations.json`), through the
# new-key rule in lib/extracted. The generator (./default.nix), the drift
# check and the rows regeneration (./extraction.nix) all call this, so the
# table exists once.
#
#   settings   the tool's own keys. A row fills `type` or `description`
#              when the source cannot state it, replaces one it names in
#              `replace`, and adds `defaultDescription` or `note`, prose no
#              extractor derives. A key the tool reads needs `description`
#              and `type`; a write-only key becomes no option (the
#              generator excludes it for `reads == {}`), so it needs
#              neither. A computed upstream default needs
#              `defaultDescription`: the option text alone would say only
#              "whatever `<expr>` computes" (git-revise's `revise.rerere`
#              reads `rr_cache.is_dir()`).
#   deadKeys   key-shaped names the source declares or mentions and never
#              reads. Only a person can say why, so each needs a `reason`
#              row. A dead key that is read again becomes a setting and
#              leaves its row `removed`, which `ignored` on a settings row
#              would hide.
#
# Returns `results` (per surface: entries, added, failures) and `file`, the
# rows with a `{}` row for every new name the rule accepts.
{
  extracted,
  lib,
  rows,
}: let
  inherit (import ../extracted/reconcile.nix {inherit lib;}) reconcile withAdded;
  reconciled = reconcile {
    deadKeys = {
      facts = extracted.deadKeys;
      needs = ["reason"];
      rows = rows.deadKeys;
      # Dead keys carry no value into Nix.
      secretNeeds = [];
    };
    settings = {
      facts = extracted.settings;
      # Which of these a key needs depends on its entry, so `needs` below
      # decides; listing them here lets a row fill or replace them.
      fields = ["defaultDescription" "description" "note" "type"];
      rows = rows.settings;
      # No settings row field delivers a value outside the store; a name the
      # classifier calls secret is never auto-accepted, so it waits for a
      # person to write its row.
      secretNeeds = [];
    };
  };
  needs = entry:
    lib.optionals (entry.reads != {}) (lib.filter (field: entry.${field} or null == null) ["description" "type"])
    ++ lib.optional (entry ? defaultExpr && entry.defaultDescription or null == null) "defaultDescription";
  # Like reconcile's own `needs`: needs-human, never auto-added.
  needing = lib.filterAttrs (_: fields: fields != []) (lib.mapAttrs (_: needs) reconciled.settings.entries);
  results =
    reconciled
    // {
      settings =
        reconciled.settings
        // {
          added = lib.subtractLists (builtins.attrNames needing) reconciled.settings.added;
          failures =
            lib.filter (failure: !(failure.kind == "unrecorded" && needing ? ${failure.name})) reconciled.settings.failures
            ++ lib.mapAttrsToList (name: details: {
              inherit details name;
              kind = "needs-human";
              surface = "settings";
            })
            needing;
        };
    };
in {
  inherit results;
  file = withAdded rows results;
}
