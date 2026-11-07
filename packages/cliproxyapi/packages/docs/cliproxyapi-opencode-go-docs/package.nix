{
  pkgs,
  repoPath,
  webDocsLib,
  ...
}: let
  snapshotDate = "2026-10-30";
  contentHash = "sha256-566yMtE4UYIvCQ6AY904no/XLU6zYT3i7zypRNUNKe8=";
  hash = "sha256-yLnpgaaBGwTm3ycn79XGi4kmFhund4tK+Ow55tQb5Ms=";
  python = pkgs.python3.withPackages (packages: [packages.markdown-it-py]);
in
  (webDocsLib {inherit pkgs;}).mkSnapshot {
    name = "cliproxyapi-opencode-go-docs";
    inherit contentHash hash snapshotDate;
    pin = repoPath ./package.nix;
    sources = [
      {
        path = "go.md";
        url = "https://opencode.ai/v2/docs/console/go/";
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
      homepage = "https://opencode.ai/v2/docs/console/go/";
      license = pkgs.lib.licenses.unfree;
      platforms = pkgs.lib.platforms.unix;
    };
  }
