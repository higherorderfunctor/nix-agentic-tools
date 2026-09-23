{pkgs, ...}: {
  imports = [
    ./checks/kimchi-extracted.nix
    ./checks/module-eval.nix
    ./checks/native-options.nix
  ];
  testing.homeManagerAiPackages.kimchi = pkgs.writeShellScriptBin "kimchi" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    exec true
  '';
}
