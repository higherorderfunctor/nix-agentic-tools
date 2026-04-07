# Instantiate `ourPkgs` from `inputs.nixpkgs` so every build input
# (buildNpmPackage, nodejs, makeWrapper) routes through this repo's
# pinned nixpkgs instead of the consumer's. This is what gives the
# store path cache-hit parity against CI's standalone build — see
# dev/fragments/overlays/cache-hit-parity.md.
{inputs}: {
  nv-sources,
  stdenv,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  inherit (ourPkgs) buildNpmPackage makeWrapper nodejs;
  nv = nv-sources.sequential-thinking-mcp;
in
  buildNpmPackage {
    pname = "sequential-thinking-mcp";
    inherit (nv) version src npmDepsHash;
    sourceRoot = "package";
    postPatch = "cp ${./locks/sequential-thinking-mcp-package-lock.json} package-lock.json";
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
  }
