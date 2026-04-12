# any-buddy — source-only package for buddy salt search worker.
# Not a built CLI — we invoke src/finder/worker.ts directly via Bun.
#
# The `...` absorbs the `inputs` arg that packages/ai-clis/default.nix
# threads through every per-package import for Phase 3.7 of the
# architecture-foundation plan (cache-hit parity). any-buddy is
# source-only so it never needs `ourPkgs`; dropping `inputs` on
# the floor here is the intent.
{final, ...}: let
  vu = import ./lib.nix;
  rev = "646c69558b622ab0e2814c58aa82143e56b76c33";
in
  final.stdenvNoCC.mkDerivation {
    pname = "any-buddy";
    version = vu.mkVersion {
      upstream = "0.0.0";
      inherit rev;
    };
    src = final.fetchFromGitHub {
      owner = "cpaczek";
      repo = "any-buddy";
      inherit rev;
      hash = "sha256-nkAeA2MuBmiDcBjIGzIbfxt0nvkHC++OSD+OWWwQ/e0=";
    };

    dontBuild = true;
    dontFixup = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r . $out/
      runHook postInstall
    '';

    meta = {
      description = "Source tree for any-buddy salt search worker";
      homepage = "https://github.com/cpaczek/any-buddy";
      license = final.lib.licenses.wtfpl;
    };
  }
