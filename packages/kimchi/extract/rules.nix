# One surface table for consumers, regeneration and the drift check.
{
  extracted ? builtins.fromJSON (builtins.readFile ../extracted.json),
  extractedLib,
  pkgs,
}: let
  inherit (pkgs) lib;
  inherit (extractedLib {inherit pkgs;}) reconcile withAdded;
  annotations = ./annotations.json;
  rows = builtins.fromJSON (builtins.readFile annotations);
  results = reconcile {
    config = {
      facts = extracted.config.keys;
      fields = ["aliasFor" "excluded"];
      needs = ["type"];
      rows = rows.config;
      secretNeeds = ["excluded"];
    };
    environment = {
      facts = extracted.environment.variables;
      fields = ["controls"];
      needs = ["controls"];
      # Duplicate names or groups with unknown fields become bad-row data.
      rows =
        lib.zipAttrsWith (_: matches:
          if builtins.length matches == 1
          then builtins.head matches
          else builtins.head matches // {"listed by more than one environment row or ignore group" = true;})
        ([rows.environment]
          ++ map (group:
            lib.genAttrs group.names (_:
              {ignored = group.reason;}
              // lib.optionalAttrs (builtins.attrNames group != ["names" "reason"]) {
                "unknown environment ignore group fields" = true;
              }))
          (builtins.attrValues rows.environmentIgnored));
      # String facts classify unrecorded secret names; a recorded controls row
      # is their review, so no additional secret fields are required.
      secretNeeds = [];
    };
  };
in {
  inherit results;
  file = withAdded rows results;
}
