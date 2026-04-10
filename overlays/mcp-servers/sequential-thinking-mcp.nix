# sequential-thinking-mcp — builds from modelcontextprotocol/servers mono-repo.
# Source: nv.src is the full mono-repo at HEAD. Version read from
# src/sequentialthinking/package.json at eval time.
{
  inputs,
  final,
  nv,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) buildNpmPackage makeWrapper nodejs;

  # Read version from the mono-repo source at eval time
  packageJson = builtins.fromJSON (builtins.readFile "${nv.src}/src/sequentialthinking/package.json");
in
  buildNpmPackage {
    pname = "sequential-thinking-mcp";
    inherit (packageJson) version;
    inherit (nv) src;
    sourceRoot = "source/src/sequentialthinking";
    postPatch = "cp ${../locks/sequential-thinking-mcp-package-lock.json} package-lock.json";
    npmDepsHash = nv.npmDepsHash or (builtins.fromJSON (builtins.readFile ../hashes.json)).sequential-thinking-mcp.npmDepsHash or "";
    dontNpmBuild = true;
    nativeBuildInputs = [makeWrapper];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/sequential-thinking-mcp $out/bin
      cp -r dist node_modules package.json $out/lib/sequential-thinking-mcp/
      makeWrapper ${nodejs}/bin/node $out/bin/sequential-thinking-mcp \
        --add-flags "$out/lib/sequential-thinking-mcp/dist/index.js"
      runHook postInstall
    '';
    meta.mainProgram = "sequential-thinking-mcp";
  }
