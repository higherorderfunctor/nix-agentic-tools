{
  pkgs,
  packageLib,
  repoPath,
  ...
}: let
  publisher = "Qwen";
  repo = "Qwen3-Embedding-0.6B-GGUF";
  rev = "370f27d7550e0def9b39c1f16d3fbaa13aa67728";
  file = "Qwen3-Embedding-0.6B-Q8_0.gguf";
  model = packageLib.fetchModel {
    inherit file pkgs publisher repo rev;
    format = "gguf";
    sha256Hex = "06507c7b42688469c4e7298b0a1e16deff06caf291cf0a5b278c308249c3e439";
    # This CDN serves the same 639,150,592 bytes as Qwen's LFS object.
    # Its unversioned URL remains safe because every mirror uses one hash.
    mirrors = ["https://d3j0sthz5doyui.cloudfront.net/models/qwen3-embedding-0.6b.gguf"];
    description = "Qwen3-Embedding-0.6B Q8_0 GGUF embedding model";
    license = pkgs.lib.licenses.asl20;
    # The embedding repos omit LICENSE. This is the base-model Apache text,
    # preserved from the original KiroCrew model distribution.
    licenseFile = ../../../licenses/Apache-2.0;
    attribution = ''
      Qwen3-Embedding-0.6B, Q8_0 GGUF quantization.

      Copyright the Qwen team, Alibaba Cloud.
      Licensed under the Apache License, Version 2.0; see LICENSE.

      Upstream: https://huggingface.co/${publisher}/${repo}
      Revision: ${rev}

      Redistributed unmodified. The licence declaration is the GGUF header's
      own `general.license` field, read from these exact bytes.
    '';
  };
in
  model.overrideAttrs (old: {
    # The updater follows upstream revisions. Verify their embedded licence at
    # build time so a hash update cannot silently outlive the Apache notice.
    buildCommand =
      ''
        ${pkgs.python3.withPackages (ps: [ps.gguf])}/bin/python3 ${../../../scripts/check-license.py} "$model"
      ''
      + old.buildCommand;
    passthru =
      old.passthru
      // {
        updateScript = pkgs.writeShellScript "update-qwen-model" ''
          set -euETo pipefail
          shopt -s inherit_errexit 2>/dev/null || :
          exec ${pkgs.python3}/bin/python3 ${../../../scripts/update-model.py} \
            --nix ${pkgs.nix}/bin/nix \
            --recipe ${pkgs.lib.escapeShellArg (repoPath ./package.nix)} \
            --publisher ${pkgs.lib.escapeShellArg publisher} \
            --repo ${pkgs.lib.escapeShellArg repo} \
            --file ${pkgs.lib.escapeShellArg file} "$@"
        '';
      };
  })
