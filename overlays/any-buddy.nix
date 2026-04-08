# any-buddy — source-only package for buddy salt search worker.
# Not a built CLI — we invoke src/finder/worker.ts directly via Bun.
#
# The `...` absorbs the `inputs` arg that packages/ai-clis/default.nix
# threads through every per-package import for Phase 3.7 of the
# architecture-foundation plan (cache-hit parity). any-buddy is
# source-only so it never needs `ourPkgs`; dropping `inputs` on
# the floor here is the intent.
{
  final,
  nv,
  ...
}:
final.stdenvNoCC.mkDerivation {
  pname = "any-buddy";
  inherit (nv) version src;

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
