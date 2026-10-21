{pkgs, ...}: {
  imports = [
    ./checks/command-shell.nix
    ./checks/docs-skill.nix
    ./checks/kimchi-codeql.nix
    ./checks/kimchi-extracted.nix
    ./checks/module-eval.nix
    ./checks/native-options.nix
    ./checks/package-identity.nix
    ./checks/workflows-source.nix
  ];
  testing.homeManagerAiPackages.kimchi = pkgs.writeShellScriptBin "kimchi" ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    exec true
  '';
}
