{
  lib,
  pkgs,
  self,
  ...
}: let
  package = pkgs.ai.gitTools.git-revise;
in {
  imports = [./checks/git-revise-extracted.nix];
  checks = {
    git-revise-package = assert package.drvPath == self.ciPackages.${pkgs.stdenv.hostPlatform.system}.git-revise.drvPath;
      pkgs.runCommandLocal "git-revise-package" {} ''
        ${lib.getExe package} --help | grep -F -- '--autosquash'
        mkdir -p "$out"
      '';
  };
}
