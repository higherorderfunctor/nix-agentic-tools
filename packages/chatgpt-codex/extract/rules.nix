# Check the root flags the launcher passes against the extracted CLI.
{
  extracted ? builtins.fromJSON (builtins.readFile ../extracted.json),
  extractedLib,
  pkgs,
}: let
  inherit (pkgs) lib;
  inherit (extractedLib {inherit pkgs;}) reconcile;
  launcherFlags = import ../lib/launcher-flags.nix;
  results = reconcile {
    # The launcher passes its flags before any subcommand, so they are checked
    # against the root command's flags alone.
    launcherFlags = {
      facts = lib.genAttrs (lib.intersectLists (lib.concatLists (builtins.attrValues launcherFlags)) (map (flag: builtins.head flag.names) extracted.cli.globalFlags)) (_: {});
      rows = {};
      secretNeeds = [];
      uses = lib.foldlAttrs (uses: policy: flags:
        uses // lib.genAttrs flags (_: "lib/launcher-flags.nix ${policy}")) {}
      launcherFlags;
    };
  };
in {
  inherit results;
}
