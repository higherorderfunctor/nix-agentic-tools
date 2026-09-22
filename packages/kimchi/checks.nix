{pkgs, ...}: {
  imports = [./checks/docs-skill.nix ./checks/kimchi-docs-links.nix ./checks/module-eval.nix];
  testing.homeManagerAiPackages.kimchi = pkgs.writeShellScriptBin "kimchi" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    exec true
  '';
}
