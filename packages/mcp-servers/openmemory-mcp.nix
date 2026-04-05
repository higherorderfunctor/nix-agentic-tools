final: let
  nv = final.nv-sources.openmemory-mcp;
in
  final.buildNpmPackage {
    pname = "openmemory-mcp";
    inherit (nv) version src npmDepsHash;
    sourceRoot = "package";
    postPatch = "cp ${./locks/openmemory-mcp-package-lock.json} package-lock.json";
    dontNpmBuild = true;
    nativeBuildInputs = [final.makeWrapper];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/openmemory-mcp $out/bin
      cp -r bin dist node_modules package.json $out/lib/openmemory-mcp/
      makeWrapper ${final.nodejs}/bin/node $out/bin/openmemory-mcp \
        --add-flags "$out/lib/openmemory-mcp/bin/opm.js" \
        --add-flags "mcp"
      makeWrapper ${final.nodejs}/bin/node $out/bin/openmemory-mcp-serve \
        --add-flags "$out/lib/openmemory-mcp/bin/opm.js" \
        --add-flags "serve"
      runHook postInstall
    '';
  }
