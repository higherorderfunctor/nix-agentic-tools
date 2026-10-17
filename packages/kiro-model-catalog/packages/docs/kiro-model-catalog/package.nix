{
  extractedLib,
  pkgs,
  repoPath,
  webDocsLib,
  ...
}: let
  inherit (pkgs) lib;
  snapshotDate = "2026-10-17";
  contentHash = "sha256-nU+EMc5whtjnRu9KvmK54UmiJthKhOniIbwaCg0+/HQ=";
  hash = "sha256-LkDDvO1PuVxeSO1IRWpmt1RGq1iQl0/Hm50zIQRB4F4=";
  snapshot = (webDocsLib {inherit pkgs;}).mkSnapshot {
    name = "kiro-model-documentation";
    inherit contentHash hash snapshotDate;
    pin = repoPath ./package.nix;
    sources = [
      {
        url = "https://kiro.dev/docs/models.md";
        path = "models.md";
      }
    ];
    validate = ''
      ${pkgs.python3}/bin/python3 ${../../../extract/models.py} "$1/models.md" > /dev/null
    '';
    afterUpdate = (extractedLib {inherit pkgs;}).regenCommand {name = "kiro-model-catalog";};
    meta = {
      description = "Pinned Kiro public model documentation";
      homepage = "https://kiro.dev/docs/models/";
      license = lib.licenses.unfree;
      platforms = lib.platforms.unix;
    };
  };
in
  pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "kiro-model-catalog";
    version = snapshotDate;
    src = snapshot;
    nativeBuildInputs = [pkgs.python3];
    phases = ["buildPhase"];
    buildPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      python3 ${../../../extract/models.py} "$src/models.md" > "$out"
    '';
    passthru = {
      extracted = finalAttrs.finalPackage;
      inherit (snapshot) updateScript;
    };
    meta = {
      description = "Kiro model slug suggestions from an independently pinned public catalog";
      homepage = "https://kiro.dev/docs/models/";
      license = lib.licenses.unfree;
      platforms = lib.platforms.unix;
    };
  })
