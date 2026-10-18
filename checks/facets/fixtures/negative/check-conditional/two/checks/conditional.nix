{
  activateConditionalCheck,
  config,
  lib,
  options,
  pkgs,
  ...
}: {
  checks = lib.mkIf (activateConditionalCheck && options ? testing.moduleProbes && config.testing.moduleProbes != []) {
    shared = lib.mkForce (pkgs.runCommandLocal "facet-conditional-two" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      touch "$out"
    '');
  };
}
