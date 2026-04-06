# any-buddy — source-only package for buddy salt search worker.
# Not a built CLI — we invoke src/finder/worker.ts directly via Bun.
{
  final,
  nv,
}:
final.stdenvNoCC.mkDerivation {
  pname = "any-buddy-source";
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
