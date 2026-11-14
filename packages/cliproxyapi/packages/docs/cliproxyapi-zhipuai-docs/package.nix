{
  pkgs,
  repoPath,
  webDocsLib,
  ...
}: let
  snapshotDate = "2026-11-10";
  contentHash = "sha256-thRFWjbZ4LdT55WBPZz0evT2pWOChvP4vlg6DeSdzpA=";
  hash = "sha256-/py51yZcTAgYuCMHXeiRg+htJtu2aaDapBf6010zT/E=";
  python = pkgs.python3.withPackages (packages: [packages.markdown-it-py]);
in
  (webDocsLib {inherit pkgs;}).mkSnapshot {
    name = "cliproxyapi-zhipuai-docs";
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
      ${python}/bin/python3 ${../../../extract/zhipuai.py} "$1/claude.md" "$1/overview.md" "$1/quick-start.md" > /dev/null
    '';
    meta = {
      description = "Pinned official z.ai model and API documentation for CLIProxyAPI defaults";
      homepage = "https://docs.z.ai/";
      license = pkgs.lib.licenses.unfree;
      platforms = pkgs.lib.platforms.unix;
    };
  }
