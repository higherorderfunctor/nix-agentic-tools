# Explicit, data-driven database tasks: never part of shell entry.
{pkgs, ...}: let
  inherit (pkgs) lib;
  databases = builtins.fromJSON (builtins.readFile ../codeql-databases.json);
  lifecycle = import ../codeql-lifecycle.nix {inherit pkgs;};
  task = name: arguments: description: {
    inherit name;
    value = {
      inherit description;
      exec = ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        exec ${lib.getExe lifecycle} ${arguments}
      '';
    };
  };
in {
  tasks = lib.listToAttrs (
    [
      (task "codeql:gc" "gc" "Prune unused CodeQL bases and orphan checkout generations")
      (task "codeql:status" "status" "Show CodeQL generations, ages, sizes and shared-base references")
    ]
    ++ lib.concatMap (name:
      map (action:
        task "codeql:${name}:${action}" "${action} ${name}" "${action} the ${name} CodeQL database in this checkout") ["down" "refresh" "up"])
    (builtins.attrNames databases)
  );
}
