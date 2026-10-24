{
  extractedLib,
  pkgs,
  repoPath,
  webDocsLib,
  ...
}: let
  snapshotDate = "2026-10-24";
  contentHash = "sha256-yXibMeocNtS7nHQ+n6UEIElhIg6Q87JwP9W+JZh3MZg=";
  hash = "sha256-w0t8r2KGf9wmyjVsTCE1TRhPKcn5ldLyVCrKDRjeYZk=";
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
        path = "devpack-quick-start.md";
        url = "https://docs.z.ai/devpack/quick-start.md";
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
      ${python}/bin/python3 ${../../../extract/z-ai.py} "$1/claude.md" "$1/devpack-quick-start.md" "$1/overview.md" "$1/quick-start.md" > /dev/null
    '';
    afterUpdate = (extractedLib {inherit pkgs;}).regenCommand {name = "cliproxyapi";};
    meta = {
      description = "Pinned official z.ai model and API documentation for CLIProxyAPI defaults";
      homepage = "https://docs.z.ai/";
      license = pkgs.lib.licenses.unfree;
      platforms = pkgs.lib.platforms.unix;
    };
  }
