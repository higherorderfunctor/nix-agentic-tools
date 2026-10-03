# writeShellApplication wrapper for the PR-monitoring Stop hook. `gh` and `git`
# come from runtimeInputs so the hook works under a stripped PATH; `gh` being
# absent is handled inside the script as a fail-open, because a consumer may
# wire this hook without wanting a GitHub dependency. `gh` is this repo's pinned
# `ai.devTools.gh`, so the hook follows its release cadence rather than the
# caller's nixpkgs pin.
{pkgs, ...}: let
  shellStrict = import ../config/shell-strict.nix;
in
  pkgs.writeShellApplication {
    name = "pr-watch-at-stop";
    runtimeInputs = [
      pkgs.ai.devTools.gh
      pkgs.coreutils
      pkgs.git
      pkgs.python3
    ];
    extraShellCheckFlags = shellStrict.shellcheckFlags;
    inherit (shellStrict) bashOptions;
    # No shoptHeader: pr-watch-at-stop.sh carries the full strict-mode header
    # itself, because prek lints it standalone as a tracked *.sh.
    text = builtins.readFile ./pr-watch-at-stop.sh;
  }
