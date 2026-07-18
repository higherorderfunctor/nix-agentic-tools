# writeShellApplication wrapper for the Stop-hook validator. runtimeInputs
# give it absolute-PATH access to git/python3/prek under a stripped PATH
# (nix-standards). `prek` = config.git-hooks.package (the pre-commit suite).
{
  pkgs,
  config,
  ...
}:
pkgs.writeShellApplication {
  name = "validate-at-stop";
  runtimeInputs = [
    config.git-hooks.package
    pkgs.coreutils
    pkgs.git
    pkgs.python3
  ];
  text = builtins.readFile ./validate-at-stop.sh;
}
