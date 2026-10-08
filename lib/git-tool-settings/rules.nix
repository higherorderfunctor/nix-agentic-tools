# Reconcile extracted settings with hand annotations. Read settings need a
# type; descriptions, default prose and dead-key reasons are optional.
# Meaningful hand rows must still name an extracted key. The generator's
# exclusions are the only way to omit a setting: an ignored settings row
# would bypass its type requirement without reporting the exclusion.
{
  extracted,
  lib,
  rows,
}: let
  inherit (import ../extracted/reconcile.nix {inherit lib;}) reconcile;
  reconciled = reconcile {
    deadKeys = {
      facts = extracted.deadKeys;
      fields = ["reason"];
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
  # A write-only key becomes no option, so it needs no type.
  needs = entry: lib.optional (entry.reads != {} && entry.type or null == null) "type";
  needing = lib.filterAttrs (_: fields: fields != []) (lib.mapAttrs (_: needs) reconciled.settings.entries);
  # `exclusions` (./default.nix) is the one way to give a key no option: it
  # reports the key in `report.excluded`. An ignored settings row would drop
  # the option and skip its needs unreported.
  ignoredSettings = lib.filter (name: rows.settings.${name} ? ignored) (builtins.attrNames rows.settings);
  results =
    reconciled
    // {
      settings =
        reconciled.settings
        // {
          failures =
            reconciled.settings.failures
            ++ lib.mapAttrsToList (name: details: {
              inherit details name;
              kind = "needs-human";
              surface = "settings";
            })
            needing
            ++ map (name: {
              inherit name;
              details = ["a settings row cannot be ignored; give the key no option in the owner's `exclusions`"];
              kind = "bad-row";
              surface = "settings";
            })
            ignoredSettings;
        };
    };
in {
  inherit results;
}
