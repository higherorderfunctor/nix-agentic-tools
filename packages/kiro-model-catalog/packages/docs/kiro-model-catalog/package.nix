{
  extractedLib,
  pkgs,
  repoPath,
  ...
}: let
  inherit (pkgs) lib;
  snapshotDate = "2026-10-12";
  hash = "sha256-QAbMi8Qvew81XLUXuQRg5HFyhcoX7AvZgV05RUyKvoE=";
  url = "https://kiro.dev/docs/models.md";
  updateScript = import ../../../../../lib/strict-shell-application.nix pkgs {
    name = "update-kiro-model-catalog";
    runtimeInputs = [pkgs.coreutils pkgs.curl pkgs.python3];
    text = ''
      work="$(mktemp -d)"
      trap 'rm -r -- "$work"' EXIT
      curl --fail --silent --show-error --location --retry 2 --max-time 60 \
        ${lib.escapeShellArg url} -o "$work/models.md"
      # Reject a changed table shape before touching the pin or committed facts.
      changed="$(python3 ${../../../extract}/update.py ${lib.escapeShellArg (repoPath ./package.nix)} \
        "$work/models.md" "$(date -u +%F)")"
      if [[ "$changed" == false ]]; then exit 0; fi
      ${(extractedLib {inherit pkgs;}).regenCommand {name = "kiro-model-catalog";}}
    '';
  };
in
  pkgs.stdenvNoCC.mkDerivation (finalAttrs: {
    pname = "kiro-model-catalog";
    version = snapshotDate;
    src = pkgs.fetchurl {inherit hash url;};
    nativeBuildInputs = [pkgs.python3];
    phases = ["buildPhase"];
    buildPhase = ''
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      python3 ${../../../extract/models.py} "$src" > "$out"
    '';
    passthru = {
      extracted = finalAttrs.finalPackage;
      updateScript = lib.getExe updateScript;
    };
    meta = {
      description = "Kiro model slug suggestions from an independently pinned public catalog";
      homepage = "https://kiro.dev/docs/models/";
      license = lib.licenses.unfree;
      platforms = lib.platforms.unix;
    };
  })
