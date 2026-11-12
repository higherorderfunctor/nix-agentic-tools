{
  extractedLib,
  pkgs,
  repoPath,
  ...
}: let
  inherit (pkgs) lib;
  extracted = extractedLib {inherit pkgs;};
  facts = extracted.load {dir = ../../../extracted;};
  updater = import ../../../../../lib/strict-shell-application.nix pkgs {
    name = "update-kiro-model-catalog";
    text = ''
      exec ${pkgs.python3}/bin/python3 ${../../../extract/catalog.py} \
        ${pkgs.ai.kiro-cli.unwrapped}/bin/kiro-cli \
        ${lib.escapeShellArg (repoPath ../../../extracted + "/extracted.json")}
    '';
  };
in
  assert facts.failures == [];
    pkgs.stdenvNoCC.mkDerivation {
      pname = "kiro-model-catalog";
      version = "1";
      phases = ["buildPhase"];
      buildPhase = ''
        set -euETo pipefail
        shopt -s inherit_errexit 2>/dev/null || :
        cp ${pkgs.writeText "kiro-models.json" (builtins.toJSON {models = extracted.get facts.aggregate "models";})} "$out"
      '';
      passthru.updateScript = lib.getExe updater;
      meta = {
        description = "Kiro model suggestions from the authenticated CLI catalog";
        homepage = "https://kiro.dev/docs/models/";
        license = lib.licenses.unfree;
        platforms = lib.platforms.unix;
      };
    }
