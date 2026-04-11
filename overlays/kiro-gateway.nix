# Kiro Gateway — Python proxy API for Kiro IDE & CLI.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` so the Python
# interpreter, its package set, and the stdenvNoCC builder all
# route through this repo's pinned nixpkgs instead of the
# consumer's. This is what gives the store path cache-hit parity
# against CI's standalone build — see dev/fragments/overlays/overlay-pattern.md
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  python = ourPkgs.python314;
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
  ourPkgs.stdenvNoCC.mkDerivation {
    pname = "kiro-gateway";
    version = "unstable-2026-02-12";
    src = ourPkgs.fetchgit {
      url = "https://github.com/jwadow/kiro-gateway.git";
      rev = "e6f23c22fc5e9aa7a22e4c31af56cdc6f859afbd";
      hash = "sha256-V9sS82Jwx5y03ojNueHr+0qfp87fkACrdr7iP78Yxeo=";
    };

    dontBuild = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out/share/kiro-gateway
      cp -R . $out/share/kiro-gateway

      mkdir -p $out/bin
      cat > $out/bin/kiro-gateway <<EOF
      #!${ourPkgs.bash}/bin/bash
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
