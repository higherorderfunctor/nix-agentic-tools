# Both Harnesses read the selected client key only when their helper runs.
{
  lib,
  pkgs,
}: {
  key,
  option,
}: let
  redact = import ../../redact {inherit lib;};
in
  import ../../strict-shell-application.nix pkgs {
    name = "cpa-client-key";
    text = ''
      # Reference paths and concat literals are already shell-escaped.
      # shellcheck disable=SC2016
      ${redact.assign {
        inherit option pkgs;
        value = key;
        variable = "key";
      }}
      printf '%s' "$key"
    '';
  }
