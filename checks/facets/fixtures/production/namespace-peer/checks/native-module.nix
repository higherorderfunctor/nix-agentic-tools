{
  config,
  lib,
  nativeCheckMarker,
  options,
  pkgs,
  ...
}: {
  checks = lib.mkIf (config.testing.moduleProbes != []) {
    native-check-module = assert nativeCheckMarker == "owner-module-argument";
    assert options ? testing.moduleProbes;
    assert config.testing.moduleProbes == [{nativeCheckProbe = true;}];
      pkgs.runCommandLocal "facet-native-check-module" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        mkdir -p "$out"
        touch "$out/passed"
      '';
  };
}
