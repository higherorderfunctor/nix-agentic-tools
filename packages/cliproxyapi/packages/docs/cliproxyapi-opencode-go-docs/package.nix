{
  pkgs,
  repoPath,
  webDocsLib,
  ...
}: let
  snapshotDate = "2026-11-10";
  contentHash = "sha256-KY5OWpPWSbeWosjzj+K8UExIFteV06cCl9wAQQt/2Ys=";
  hash = "sha256-CxniqlBxt+2lLRWE5zNgdG1Shzu3LXd2NQHK17QG9iQ=";
  python = pkgs.python3.withPackages (packages: [packages.markdown-it-py]);
in
  (webDocsLib {inherit pkgs;}).mkSnapshot {
    name = "cliproxyapi-opencode-go-docs";
    inherit contentHash hash snapshotDate;
    pin = repoPath ./package.nix;
    sources = [
      {
        path = "go.md";
        url = "https://opencode.ai/docs/console/go/";
      }
      {
        # Every response stamps each model's `created` with the fetch time.
        normalize = ''
          ${pkgs.jq}/bin/jq -S 'del(.data[].created) | .data |= sort_by(.id)'
        '';
        path = "models.json";
        url = "https://opencode.ai/inference/go/v1/models";
      }
    ];
    validate = ''
      ${python}/bin/python3 ${../../../extract/opencode-go.py} "$1/models.json" "$1/go.md" > /dev/null
    '';
    meta = {
      description = "Pinned OpenCode Go model catalog and plan limits documentation for CLIProxyAPI defaults";
      homepage = "https://opencode.ai/docs/console/go/";
      license = pkgs.lib.licenses.unfree;
      platforms = pkgs.lib.platforms.unix;
    };
  }
