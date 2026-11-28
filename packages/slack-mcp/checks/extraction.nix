{
  extractedLib,
  pkgs,
  self,
  ...
}: let
  inherit (pkgs.stdenv.hostPlatform) system;
  package = self.ciPackages.${system}.slack-mcp;
in {
  checks =
    {
      # The drift check below already runs the extractor on the untouched pin
      # and compares all output. This check exercises degraded copies only.
      slack-mcp-extract-guard = pkgs.runCommand "slack-mcp-extract-guard" {} ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        ${pkgs.python3}/bin/python3 -I ${./extract-guard.py} \
          ${../extract/slack.py} ${package.src}/slack-mcp-server.md
        touch "$out"
      '';
    }
    // (extractedLib {inherit pkgs;}).mkOwnerCheck {
      dir = ../extracted;
      name = "slack-mcp";
      inherit package;
    };
}
