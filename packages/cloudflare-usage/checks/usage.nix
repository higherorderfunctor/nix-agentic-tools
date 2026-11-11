{
  pkgs,
  self,
  ...
}: let
  package = self.packages.${pkgs.stdenv.hostPlatform.system}.cloudflare-usage;
in {
  checks = pkgs.lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
    cloudflare-usage = pkgs.runCommand "cloudflare-usage" {} ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      ${pkgs.python3}/bin/python3 ${./usage.py} ${package.source} ${package}/bin/cloudflare-usage
      touch "$out"
    '';
  };
}
