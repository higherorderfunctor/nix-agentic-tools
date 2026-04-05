final: let
  nv = final.nv-sources.sequential-thinking-mcp;
in
  final.buildNpmPackage {
    pname = "sequential-thinking-mcp";
    inherit (nv) version src npmDepsHash;
    sourceRoot = "package";
    postPatch = "cp ${./locks/sequential-thinking-mcp-package-lock.json} package-lock.json";
    dontNpmBuild = true;
    nativeBuildInputs = [final.makeWrapper];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/sequential-thinking-mcp $out/bin
      cp -r dist node_modules package.json $out/lib/sequential-thinking-mcp/
      makeWrapper ${final.nodejs}/bin/node $out/bin/sequential-thinking-mcp \
        --add-flags "$out/lib/sequential-thinking-mcp/dist/index.js"
      runHook postInstall
    '';
  }
