{
  inputs,
  lib,
  pkgs,
  ...
}: {
  imports = [./darwin-cache-gate.nix ./devenv-inputs.nix ./formatting.nix ./unique-map-keys-fixtures.nix];
  checks = (import ../../config/repo-validation.nix {inherit lib pkgs;}).mkCiChecks {
    gitHooksRun = inputs.git-hooks.lib.${pkgs.stdenv.hostPlatform.system}.run;
    src = ../..;
  };
}
