final: let
  nv = final.nv-sources.effect-mcp;
in
  final.stdenv.mkDerivation {
    pname = "effect-mcp";
    inherit (nv) version src;
    sourceRoot = ".";
    dontBuild = true;
    nativeBuildInputs = [final.makeWrapper];
    installPhase = ''
      mkdir -p $out/lib/effect-mcp $out/bin
      cp package/main.cjs $out/lib/effect-mcp/
      makeWrapper ${final.nodejs}/bin/node $out/bin/effect-mcp \
        --add-flags "$out/lib/effect-mcp/main.cjs"
    '';
  }
