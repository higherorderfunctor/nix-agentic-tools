# Kiro Gateway — Python proxy API for Kiro IDE & CLI.
#
# The `...` absorbs the `inputs` arg that packages/ai-clis/default.nix
# threads through every per-package import for Phase 3.7 of the
# architecture-foundation plan (cache-hit parity). Not yet consumed
# in this file; plumbing-only for now.
{
  final,
  nv,
  ...
}: let
  python = final.python314;
  pythonEnv = python.withPackages (ps:
    with ps; [
      fastapi
      httpx
      loguru
      python-dotenv
      tiktoken
      uvicorn
    ]);
in
  final.stdenvNoCC.mkDerivation {
    pname = "kiro-gateway";
    inherit (nv) src version;

    dontBuild = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out/share/kiro-gateway
      cp -R . $out/share/kiro-gateway

      mkdir -p $out/bin
      cat > $out/bin/kiro-gateway <<EOF
      #!${final.bash}/bin/bash
      set -euETo pipefail
      shopt -s inherit_errexit 2>/dev/null || :
      exec ${pythonEnv}/bin/python "$out/share/kiro-gateway/main.py" "\$@"
      EOF
      chmod +x $out/bin/kiro-gateway

      runHook postInstall
    '';

    meta = {
      description = "Proxy API gateway for Kiro IDE & CLI";
      mainProgram = "kiro-gateway";
    };
  }
