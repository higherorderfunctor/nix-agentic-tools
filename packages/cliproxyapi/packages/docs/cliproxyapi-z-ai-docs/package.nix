{
  extractedLib,
  pkgs,
  repoPath,
  webDocsLib,
  ...
}: let
  snapshotDate = "2026-10-23";
  contentHash = "sha256-mU07psxSu0/hB1wRY2UgxKltWb3BB6/CUIHd0O36REo=";
  hash = "sha256-laaSldrFiecsTYoCE2D8q8r29l02gkFeRCk02PDzXso=";
  python = pkgs.python3.withPackages (packages: [packages.markdown-it-py]);
in
  (webDocsLib {inherit pkgs;}).mkSnapshot {
    name = "cliproxyapi-z-ai-docs";
    inherit contentHash hash snapshotDate;
    pin = repoPath ./package.nix;
    sources = [
      {
        path = "claude.md";
        url = "https://docs.z.ai/devpack/tool/claude.md";
      }
      {
        path = "overview.md";
        url = "https://docs.z.ai/guides/overview/overview.md";
      }
      {
        path = "quick-start.md";
        url = "https://docs.z.ai/guides/overview/quick-start.md";
      }
    ];
    validate = ''
      ${python}/bin/python3 ${../../../extract/z-ai.py} "$1/claude.md" "$1/overview.md" "$1/quick-start.md" > /dev/null
    '';
    afterUpdate = (extractedLib {inherit pkgs;}).regenCommand {name = "cliproxyapi";};
    meta = {
      description = "Pinned official z.ai model and API documentation for CLIProxyAPI defaults";
      homepage = "https://docs.z.ai/";
      license = pkgs.lib.licenses.unfree;
      platforms = pkgs.lib.platforms.unix;
    };
  }
