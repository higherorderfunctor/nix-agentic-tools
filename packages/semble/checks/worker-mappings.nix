{
  lib,
  pkgs,
  ...
}: let
  customizePackage = (import ../lib/default.nix).ai.semble.customizePackage {inherit lib pkgs;};
  semble = customizePackage pkgs.ai.semble {
    pathMappings = [
      {
        content = "code";
        language = "bash";
        patterns = ["scripts/*"];
      }
      {
        content = "docs";
        language = null;
        patterns = ["docs/*.py"];
      }
    ];
  };
  script = import ./semble-script.nix pkgs "worker-mappings" semble ./worker-mappings.py;
in {
  checks.semble-worker-mappings = pkgs.runCommand "semble-worker-mappings" {} ''
    set -euETo pipefail
    shopt -s inherit_errexit 2>/dev/null || :
    ${script}
    touch "$out"
  '';
}
