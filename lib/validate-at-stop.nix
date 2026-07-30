# writeShellApplication wrapper for the Stop-hook validator. runtimeInputs
# give it absolute-PATH access to git/python3/prek under a stripped PATH
# (nix-standards). `prek` = config.git-hooks.package (the pre-commit suite).
{
  pkgs,
  config,
  ...
}: let
  shellStrict = import ../config/shell-strict.nix;
in
  pkgs.writeShellApplication {
    name = "validate-at-stop";
    runtimeInputs = [
      config.git-hooks.package
      pkgs.coreutils
      pkgs.git
      pkgs.python3
    ];
    extraShellCheckFlags = shellStrict.shellcheckFlags;
    inherit (shellStrict) bashOptions;
    # No shoptHeader here: validate-at-stop.sh carries the full strict-mode
    # header itself, because it must also be valid standalone (prek lints it
    # as a tracked *.sh).
    text = builtins.readFile ./validate-at-stop.sh;
  }
