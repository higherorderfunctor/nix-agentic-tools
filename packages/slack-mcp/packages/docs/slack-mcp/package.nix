{
  pkgs,
  repoPath,
  webDocsLib,
  ...
}: let
  inherit (pkgs) lib;
  snapshotDate = "2026-11-18";
  contentHash = "sha256-Hti11tswZFiV1SeXwMOhD/yM3GPHdCKw7piyG8gkx38=";
  hash = "sha256-qp+aj89WIQlASvWHTdhGNf4nhMFWPgXLaz+QgRjAgkw=";
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
