# One surface table for consumers and the drift check.
{
  extracted ? builtins.fromJSON (builtins.readFile ../extracted.json),
  extractedLib,
  pkgs,
  # The annotation rows; a check overrides them to prove a row reaches the surface.
  rows ? builtins.fromJSON (builtins.readFile ./annotations.json),
}: let
  inherit (pkgs) lib;
  inherit (extractedLib {inherit pkgs;}) reconcile;
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
      # Optional prose: nothing reads it, and an extractor cannot derive it.
      fields = ["controls"];
      needs = [];
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
      secretNeeds = [];
    };
    harness = {
      facts = extracted.harness.keys;
      # The extractor emits a key Kimchi reads with no declared type as
      # `type = null`; a row supplies the JSON type its option needs.
      fields = ["excluded"];
      needs = ["type"];
      rows = rows.harness;
      # As in config: a secret key gets no option, and the row says why.
      secretNeeds = ["excluded"];
    };
  };
in {
  inherit results;
}
