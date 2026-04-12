# any-buddy — buddy salt search worker + CLI.
#
# Built via pnpm (tsc + tsc-alias). Source tree preserved at
# $out/src/ for the buddy activation script which invokes worker.ts via Bun.
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchFromGitHub fetchPnpmDeps nodejs pnpm stdenv;
  vu = import ./lib.nix;

  rev = "861f0dfea1674dcff9a72390143fc64d026c95ed";
  src = fetchFromGitHub {
    owner = "cpaczek";
    repo = "any-buddy";
    inherit rev;
    hash = "sha256-nkAeA2MuBmiDcBjIGzIbfxt0nvkHC++OSD+OWWwQ/e0=";
  };
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "any-buddy";
    version = vu.mkVersion {
      upstream = vu.readPackageJsonVersion "${src}/package.json";
      inherit rev;
    };
    inherit src;

    nativeBuildInputs = [nodejs pnpm.configHook];
    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      fetcherVersion = 3;
      hash = "sha256-8IY3z6f0N/0mrrU44MxcLGrexJE5sGUGhTwLJH01no8=";
    };

    buildPhase = ''
      runHook preBuild
      pnpm run build
      runHook postBuild
    '';

    doCheck = true;
    checkPhase = ''
      runHook preCheck
      HOME="$TMPDIR" pnpm exec vitest run
      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/any-buddy
      cp -r dist node_modules package.json $out/lib/any-buddy/
      # Preserve source tree for buddy activation (worker.ts invoked via Bun)
      cp -r src $out/
      runHook postInstall
    '';

    meta = {
      description = "Buddy salt search worker for Claude Code";
      homepage = "https://github.com/cpaczek/any-buddy";
      license = ourPkgs.lib.licenses.wtfpl;
    };
  })
