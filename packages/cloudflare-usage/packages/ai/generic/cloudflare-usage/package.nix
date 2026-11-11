{pkgs, ...}: let
  source = ../../../../src/cloudflare-usage.py;
in
  import ../../../../../../lib/strict-shell-application.nix pkgs {
    name = "cloudflare-usage";
    passthru = {inherit source;};
    text = ''
      exec ${pkgs.python3}/bin/python3 ${source} "$@"
    '';
    meta = {
      description = "Read daily Cloudflare Workers AI neurons through CPA";
      mainProgram = "cloudflare-usage";
    };
  }
