# One surface table for consumers, regeneration and the drift check.
{
  extracted ? builtins.fromJSON (builtins.readFile ../extracted.json),
  pkgs,
}: let
  inherit (pkgs) lib;
  inherit (import ../../../lib/extracted {inherit pkgs;}) reconcile withAdded;
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
          else null)
        ([rows.environment]
          ++ map (group:
            lib.genAttrs group.names (_:
              if builtins.attrNames group == ["names" "reason"]
              then {ignored = group.reason;}
              else null))
          (builtins.attrValues rows.environmentIgnored));
      # needs = ["controls"] already gates secret environment names.
      secretNeeds = [];
    };
  };
in {
  inherit results;
  file = withAdded rows results;
}
