{
  pkgs,
  self,
  ...
}: let
  package = self.packages.${pkgs.stdenv.hostPlatform.system}.cloudflare-usage;
in {
  checks = pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    cloudflare-usage =
      pkgs.runCommand "cloudflare-usage" {
        nativeBuildInputs = [pkgs.bash pkgs.curl pkgs.jq pkgs.python3];
      } ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${pkgs.python3}/bin/python3 ${./usage.py} ${../../delegate-routing/checks/usage-runtime.py} ${../../delegate-routing/scripts} ${package}/bin/cloudflare-usage ${../src/cloudflare-usage.sh}
        touch "$out"
      '';
  };
}
