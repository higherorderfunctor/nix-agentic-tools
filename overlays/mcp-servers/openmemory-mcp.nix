# openmemory-mcp — builds from CaviraOSS/OpenMemory mono-repo.
# Source: nv.src is the full mono-repo at HEAD. Version read from
# packages/openmemory-js/package.json at eval time.
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

  packageJson = builtins.fromJSON (builtins.readFile "${nv.src}/packages/openmemory-js/package.json");
in
  buildNpmPackage {
    pname = "openmemory-mcp";
    inherit (packageJson) version;
    inherit (nv) src;
    sourceRoot = "source/packages/openmemory-js";
    postPatch = "cp ${../locks/openmemory-mcp-package-lock.json} package-lock.json";
    inherit (nv) npmDepsHash;
    # Source needs building (tsc). npm tarball had pre-built dist/.
    nativeBuildInputs = [makeWrapper];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/openmemory-mcp $out/bin
      cp -r bin dist node_modules package.json $out/lib/openmemory-mcp/
      makeWrapper ${nodejs}/bin/node $out/bin/openmemory-mcp \
        --add-flags "$out/lib/openmemory-mcp/bin/opm.js" \
        --add-flags "mcp"
      makeWrapper ${nodejs}/bin/node $out/bin/openmemory-mcp-serve \
        --add-flags "$out/lib/openmemory-mcp/bin/opm.js" \
        --add-flags "serve"
      runHook postInstall
    '';
    meta.mainProgram = "openmemory-mcp";
  }
