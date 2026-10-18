{
  activateConditionalCheck,
  config,
  lib,
  options,
  pkgs,
  ...
}: {
  checks = lib.mkIf (config.testing.moduleProbes != []) {
    shared = assert activateConditionalCheck;
    assert options ? testing.moduleProbes;
      lib.mkForce (pkgs.runCommandLocal "facet-conditional-two" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        touch "$out"
      '');
  };
}
