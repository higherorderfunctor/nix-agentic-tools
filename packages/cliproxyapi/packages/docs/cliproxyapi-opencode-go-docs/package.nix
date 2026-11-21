{
  pkgs,
  repoPath,
  webDocsLib,
  ...
}: let
  snapshotDate = "2026-11-21";
  contentHash = "sha256-EKTiMAG0CtngNGEqccq6nu5P9S8435/i0SCwbBrnzEo=";
  hash = "sha256-bPZ9mpGkhblbYkKdJkCULjboZviINUXtar1c/NeVPyY=";
in
  (webDocsLib {inherit pkgs;}).mkSnapshot {
    name = "cliproxyapi-opencode-go-docs";
    inherit contentHash hash snapshotDate;
    pin = repoPath ./package.nix;
    sources = [
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
      ${pkgs.python3}/bin/python3 ${../../../extract/opencode-go.py} "$1/models.json" > /dev/null
    '';
    meta = {
      description = "Pinned OpenCode Go model catalog, with per-plan monthly limits, for CLIProxyAPI defaults";
      homepage = "https://opencode.ai/docs/console/go/";
      license = pkgs.lib.licenses.unfree;
      platforms = pkgs.lib.platforms.unix;
    };
  }
