{
  lib,
  pkgs,
  ...
}: {
  checks.instructions-fragment-routing = let
    generated = import ../../dev/generate.nix {inherit lib pkgs;};
    routing =
      pkgs.writeText "fragment-routing.json" (builtins.toJSON
        (lib.mapAttrs (_: rule: {inherit (rule) matcher references;}) generated.rules));
  in
    pkgs.runCommand "instructions-fragment-routing" {nativeBuildInputs = [pkgs.python3];} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      python3 ${./fragment-routing.py} ${routing}
      touch "$out"
    '';
}
