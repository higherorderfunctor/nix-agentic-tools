# Explicit, data-driven database tasks: never part of shell entry.
{pkgs, ...}: let
  inherit (pkgs) lib;
  databases = builtins.fromJSON (builtins.readFile ../codeql-databases.json);
  lifecycle = import ../codeql-lifecycle.nix {inherit pkgs;};
in {
  tasks = lib.listToAttrs (lib.concatMap (name:
    map (action: {
      name = "codeql:${name}:${action}";
      value = {
        description = "${action} the ${name} CodeQL database in this checkout";
        exec = ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          exec ${lib.getExe lifecycle} ${action} ${name}
        '';
      };
    }) ["down" "refresh" "up"])
  (builtins.attrNames databases));
}
