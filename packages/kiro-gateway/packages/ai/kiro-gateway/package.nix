# Kiro Gateway — Python proxy API for Kiro IDE & CLI.
{
  pkgs,
  packageLib,
  ...
}: let
  python = pkgs.python314;
  vu = packageLib;
  pythonEnv = python.withPackages (ps:
    with ps; [
      fastapi
      httpx
      loguru
      python-dotenv
      tiktoken
      uvicorn
    ]);

  rev = "a5292ca04c7c6231e0b47673ac3f981f5a706e1e";
  src = pkgs.fetchgit {
    url = "https://github.com/jwadow/kiro-gateway.git";
    inherit rev;
    hash = "sha256-LgZiMJXy7v0o4VbQTMYi1Yk2SjBsKj82cUC5FhhZ4zo=";
  };
in
  pkgs.stdenvNoCC.mkDerivation {
    pname = "kiro-gateway";
    # No pyproject.toml or package.json with version in upstream source
    version = vu.mkVersion {
      upstream = "0.0.0";
      inherit rev;
    };
    inherit src;

    dontBuild = true;
    doCheck = true;

    nativeCheckInputs = let
      ps = pkgs.python314Packages;
    in [
      ps.pytest
      ps.pytest-asyncio
      ps.hypothesis
    ];
    checkPhase = ''
      runHook preCheck
      ${pythonEnv}/bin/python -m pytest tests/ -v
      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p $out/share/kiro-gateway
      cp -R . $out/share/kiro-gateway

      mkdir -p $out/bin
      cat > $out/bin/kiro-gateway <<EOF
      #!${pkgs.bash}/bin/bash
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
