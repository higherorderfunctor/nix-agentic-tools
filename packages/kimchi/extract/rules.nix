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
      # Environment variables always hold strings, including names with no
      # prose yet. This supplies the classifier's string-only contract.
      facts = lib.mapAttrs (_: fact: fact // {type = "string";}) extracted.environment.variables;
      fields = ["controls"];
      needs = ["controls"];
      rows =
        rows.environment
        // builtins.listToAttrs (lib.concatMap (group:
          map (name: lib.nameValuePair name {ignored = group.reason;}) group.names)
        (builtins.attrValues rows.environmentIgnored));
      # The factory's environment delivery accepts these string variables;
      # a secret name must have a hand row documenting what it delivers.
      secretNeeds = ["controls"];
    };
  };
in {
  inherit results;
  file = withAdded annotations results;
}
