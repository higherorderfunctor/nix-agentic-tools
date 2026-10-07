# The surface table every git tool shares: its sidecar's facts against its
# rows file (`packages/<owner>/extract/annotations.json`), through the
# new-key rule in lib/extracted. The generator (./default.nix), the drift
# check and the rows regeneration (./extraction.nix) all call this, so the
# table exists once.
#
#   settings   the tool's own keys. A row fills `type` or `description`
#              when the source cannot state it, replaces one it names in
#              `replace`, and adds `defaultDescription` or `note`, prose no
#              extractor derives.
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
      fields = ["defaultDescription" "note"];
      needs = ["description" "type"];
      rows = rows.settings;
      # No settings row field delivers a value outside the store; a name the
      # classifier calls secret is never auto-accepted, so it waits for a
      # person to write its row.
      secretNeeds = [];
    };
  };
  # The option text says only "whatever `<expr>` computes" for a computed
  # upstream default (git-revise's `revise.rerere` reads `rr_cache.is_dir()`),
  # so such a key needs `defaultDescription` prose before it is accepted,
  # like any other `needs` field: needs-human, never auto-added.
  computedWithoutProse = lib.filter (name: let
    entry = reconciled.settings.entries.${name};
  in
    entry ? defaultExpr && entry.defaultDescription or null == null)
  (builtins.attrNames reconciled.settings.entries);
  results =
    reconciled
    // {
      settings =
        reconciled.settings
        // {
          added = lib.subtractLists computedWithoutProse reconciled.settings.added;
          failures =
            lib.filter (failure: !(failure.kind == "unrecorded" && builtins.elem failure.name computedWithoutProse)) reconciled.settings.failures
            ++ map (name: {
              inherit name;
              details = ["defaultDescription"];
              kind = "needs-human";
              surface = "settings";
            })
            computedWithoutProse;
        };
    };
in {
  inherit results;
  file = withAdded rows results;
}
