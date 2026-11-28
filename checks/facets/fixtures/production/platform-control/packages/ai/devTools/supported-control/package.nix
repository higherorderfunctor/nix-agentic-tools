{pkgs}:
# Evaluating from the filtered package tree cannot resolve the owner source.
assert builtins.seq (import ../../../../src/sentinel.nix) true;
  pkgs.runCommand "facet-supported-control" {
    # A copied package path can also change the sidecar dependency and drvPath.
    messageFile = ./message.txt;
  } ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    cp "$messageFile" "$out"
  ''
