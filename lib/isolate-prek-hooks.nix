# Package the shared-hook rewriter so devenv and flake checks exercise the same
# implementation rather than copying shell between a task and a fixture.
{pkgs}: let
  shellStrict = import ../config/shell-strict.nix;
in
  pkgs.writeShellApplication {
    name = "isolate-prek-hooks";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.git
      pkgs.gnugrep
      pkgs.gnused
      pkgs.util-linux
    ];
    extraShellCheckFlags = shellStrict.shellcheckFlags;
    inherit (shellStrict) bashOptions;
    text = builtins.readFile ./isolate-prek-hooks.sh;
  }
