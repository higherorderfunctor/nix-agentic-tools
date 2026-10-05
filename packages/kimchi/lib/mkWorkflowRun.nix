{pkgs}: let
  strictShellApplication = import ../../../lib/strict-shell-application.nix pkgs;
in
  strictShellApplication {
    name = "kimchi-workflow-run";
    # Resolve the operator's configured Kimchi on PATH without building it.
    runtimeInputs = [pkgs.coreutils pkgs.jq];
    text = builtins.replaceStrings ["@filter@"] ["${../src/workflow-run/read.jq}"] (builtins.readFile ../src/workflow-run/run.sh);
  }
