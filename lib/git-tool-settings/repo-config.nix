# `nix-agentic-tools-git`: the repository-local git configuration script
# (./repo-config.sh says what it does). The devenv tasks and the runtime
# checks run this one derivation, so a check exercises exactly what a shell
# entry runs.
{pkgs}: let
  shellStrict = import ../../config/shell-strict.nix;
in
  pkgs.writeShellApplication {
    name = "nix-agentic-tools-git";
    runtimeInputs = [pkgs.coreutils pkgs.git pkgs.util-linux];
    inherit (shellStrict) bashOptions;
    extraShellCheckFlags = shellStrict.shellcheckFlags;
    text = builtins.readFile ./repo-config.sh;
  }
