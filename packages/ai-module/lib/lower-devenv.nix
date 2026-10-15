{lib}: let
  activation = import ./activation.nix {inherit lib;};
in
  {
    entries,
    nativeFiles,
    secretNodes,
  }: let
    issue = activation.validate {
      backend = "devenv";
      inherit entries nativeFiles secretNodes;
    };
    active = lib.filterAttrs (_: entry: entry.enable || entry.runWhenDisabled) entries;
    nodesFor = activation.pointNodes "devenv" secretNodes;
    lower = key: entry: let
      name = activation.nativeName "devenv" key entry;
    in {
      inherit name;
      value =
        {
          after = activation.devenvAfter secretNodes entry;
          before = lib.unique (lib.concatMap nodesFor entry.before ++ entry.beforeNodes.devenv);
          exec = ''
            (
            set -euETo pipefail
            shopt -s inherit_errexit 2>/dev/null || :
            ${entry.command}
            )
          '';
        }
        # Generated entries only: the option schema has no such field.
        // lib.optionalAttrs (entry.showOutput or false) {showOutput = true;};
    };
  in
    if issue != null
    then throw issue
    else
      {
        "ai2:files-linked" = {
          after = [
            (
              if nativeFiles
              then "devenv:files"
              else if builtins.hasAttr "files2-guard" entries
              then "ai2:files2-guard"
              else "ai2:link-check"
            )
          ];
          before = ["ai2:files-ready"];
          exec = "";
        };
        "ai2:files-ready" = {
          after = ["ai2:files-linked"];
          before = ["devenv:enterShell"];
          exec = "";
        };
        "ai2:link-check" = {
          after = ["devenv:files:cleanup"];
          before = [
            (
              if builtins.hasAttr "files2-guard" entries
              then "ai2:files2-guard"
              else if nativeFiles
              then "devenv:files"
              else "ai2:files-linked"
            )
          ];
          exec = "";
        };
      }
      // builtins.listToAttrs (lib.mapAttrsToList lower active)
