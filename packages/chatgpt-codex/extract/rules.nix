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
    flags = {
      facts = lib.genAttrs (lib.unique (lib.concatMap (command: map (flag: builtins.head flag.names) command.flags) (builtins.attrValues extracted.cli.commands))) (_: {});
      rows = rows.flags;
      # Flags carry no values into Nix: the facts are untyped, so secret
      # classification does not apply.
      secretNeeds = [];
    };
    # The launcher passes its flags before any subcommand, so they are checked
    # against the root command's flags alone.
    launcherFlags = {
      facts = lib.genAttrs (lib.intersectLists (lib.concatLists (builtins.attrValues launcherFlags)) (map (flag: builtins.head flag.names) extracted.cli.globalFlags)) (_: {});
      rows = rows.launcherFlags;
      secretNeeds = [];
      uses = lib.foldlAttrs (uses: policy: flags:
        uses // lib.genAttrs flags (_: "lib/launcher-flags.nix ${policy}")) {}
      launcherFlags;
    };
  };
in {
  inherit results;
  file = withAdded rows results;
}
