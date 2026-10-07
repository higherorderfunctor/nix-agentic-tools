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
  launcherFlags = import ../lib/launcher-flags.nix;
  results = reconcile {
    commands = {
      facts = extracted.cli.commands;
      rows = rows.commands;
      secretNeeds = [];
    };
    config = {
      facts = lib.mapAttrs (_: _: {}) extracted.config;
      fields = ["disposition"];
      needs = ["disposition"];
      rows = rows.config;
      secretNeeds = [];
    };
    flags = {
      facts = lib.genAttrs (lib.unique (lib.concatMap (command: map (flag: builtins.head flag.names) command.flags) (builtins.attrValues extracted.cli.commands))) (_: {});
      rows = rows.flags;
      secretNeeds = [];
      uses = lib.foldlAttrs (uses: policy: flags:
        uses // lib.genAttrs flags (_: "mkCodex.nix launcherFlags.${policy}")) {}
      launcherFlags;
    };
  };
in {
  inherit results;
  file = withAdded rows results;
}
