{
  pkgs,
  repoPath,
  webDocsLib,
  ...
}: let
  snapshotDate = "2026-11-17";
  contentHash = "sha256-XcBKfzpumim6ZKLPIvYwV1SYlVsUUssui/FANUA883E=";
  hash = "sha256-5WxC+blilYuKuDngym5BjM0udhI1i+z5ZbvmpfVRg78=";
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
