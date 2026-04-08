# Instantiate `ourPkgs` from `inputs.nixpkgs` so every build input
# (buildNpmPackage, nodejs, makeWrapper) routes through this repo's
# pinned nixpkgs instead of the consumer's. This is what gives the
# store path cache-hit parity against CI's standalone build — see
# dev/fragments/overlays/overlay-pattern.md.
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
  nv = nv-sources.context7-mcp;
in
  buildNpmPackage {
    pname = "context7-mcp";
    inherit (nv) version src npmDepsHash;
    sourceRoot = "package";
    postPatch = "cp ${./locks/context7-mcp-package-lock.json} package-lock.json";
    dontNpmBuild = true;
    nativeBuildInputs = [makeWrapper];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/context7-mcp $out/bin
      cp -r dist node_modules package.json $out/lib/context7-mcp/
      makeWrapper ${nodejs}/bin/node $out/bin/context7-mcp \
        --add-flags "$out/lib/context7-mcp/dist/index.js"
      runHook postInstall
    '';
  }
