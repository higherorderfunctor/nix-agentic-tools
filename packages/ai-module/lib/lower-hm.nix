{
  lib,
  pkgs,
}: let
  activation = import ./activation.nix {inherit lib;};
in
  {
    entries,
    hmLib,
    secretNodes,
  }: let
    issue = activation.validate {
      backend = "hm";
      inherit entries secretNodes;
    };
    active = lib.filterAttrs (_: entry: entry.enable || entry.runWhenDisabled) entries;
    nodesFor = activation.pointNodes "hm" secretNodes;
    lower = key: entry: let
      name = activation.nativeName "hm" key entry;
      before = lib.unique (lib.concatMap nodesFor entry.before ++ entry.beforeNodes.hm);
      after = lib.unique (lib.concatMap nodesFor entry.after ++ entry.afterNodes.hm);
      body = ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${entry.command}
      '';
    in {
      inherit name;
      value = hmLib.hm.dag.entryBetween before after ''
        run ${pkgs.bash}/bin/bash -c ${lib.escapeShellArg body}
      '';
    };
  in
    if issue != null
    then throw issue
    else
      {
        "ai2-files-ready" = hmLib.hm.dag.entryBetween ["ai2-ready"] ["linkGeneration"] "";
        "ai2-ready" = hmLib.hm.dag.entryAfter ["ai2-files-ready"] "";
      }
      // builtins.listToAttrs (lib.mapAttrsToList lower active)
