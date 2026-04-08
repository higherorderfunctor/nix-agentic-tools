# Instantiate `ourPkgs` from `inputs.nixpkgs` so every build input
# (stdenv.mkDerivation, nodejs, makeWrapper) routes through this repo's
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
  inherit (ourPkgs) makeWrapper nodejs;
  nv = nv-sources.effect-mcp;
in
  ourPkgs.stdenv.mkDerivation {
    pname = "effect-mcp";
    inherit (nv) version src;
    sourceRoot = ".";
    dontBuild = true;
    nativeBuildInputs = [makeWrapper];
    installPhase = ''
      mkdir -p $out/lib/effect-mcp $out/bin
      cp package/main.cjs $out/lib/effect-mcp/
      makeWrapper ${nodejs}/bin/node $out/bin/effect-mcp \
        --add-flags "$out/lib/effect-mcp/main.cjs"
    '';
  }
