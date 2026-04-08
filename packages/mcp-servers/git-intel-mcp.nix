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
  nv = nv-sources.git-intel-mcp;
in
  buildNpmPackage {
    pname = "git-intel-mcp";
    inherit (nv) version src npmDepsHash;
    postPatch = "cp ${./locks/git-intel-mcp-package-lock.json} package-lock.json";
    nativeBuildInputs = [makeWrapper];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/git-intel-mcp $out/bin
      cp -r dist node_modules package.json $out/lib/git-intel-mcp/
      makeWrapper ${nodejs}/bin/node $out/bin/git-intel-mcp \
        --add-flags "$out/lib/git-intel-mcp/dist/index.js"
      runHook postInstall
    '';
    meta.mainProgram = "git-intel-mcp";
  }
