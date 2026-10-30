{
  pkgs,
  repoPath,
  webDocsLib,
  ...
}: let
  inherit (pkgs) lib;
  snapshotDate = "2026-10-19";
  contentHash = "sha256-z2Qn3zpIHRCNaamIaFWwamUAZqpGYL+8kzz6K8N6zX8=";
  hash = "sha256-VD8PiPM7FiIPI0glIslh5K1YiIm32FO9Yyn+ueS2BnU=";
  snapshot = (webDocsLib {inherit pkgs;}).mkSnapshot {
    name = "slack-mcp-documentation";
    inherit contentHash hash snapshotDate;
    pin = repoPath ./package.nix;
    sources = [
      {
        url = "https://docs.slack.dev/ai/slack-mcp-server.md";
        path = "slack-mcp-server.md";
      }
    ];
    validate = ''
      ${pkgs.python3}/bin/python3 ${../../../extract/slack.py} "$1/slack-mcp-server.md" > /dev/null
    '';
    meta = {
      description = "Pinned Slack MCP server documentation";
      homepage = "https://docs.slack.dev/ai/slack-mcp-server";
      license = lib.licenses.unfree;
      platforms = lib.platforms.unix;
    };
  };
in
  pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "slack-mcp";
    version = snapshotDate;
    src = snapshot;
    nativeBuildInputs = [pkgs.python3];
    phases = ["buildPhase"];
    buildPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      python3 ${../../../extract/slack.py} "$src/slack-mcp-server.md" > "$out"
    '';
    passthru = {
      extracted = finalAttrs.finalPackage;
      inherit (snapshot) updateScript;
    };
    meta = {
      description = "Slack MCP server endpoint and tool scopes from its pinned public documentation";
      homepage = "https://docs.slack.dev/ai/slack-mcp-server";
      license = lib.licenses.unfree;
      platforms = lib.platforms.unix;
    };
  })
