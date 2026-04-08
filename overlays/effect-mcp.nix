# effect-mcp — builds the Effect MCP server from the nvfetcher-tracked
# source via stdenv.mkDerivation (pre-built CJS bundle, no npm build step).
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` so every build input
# (stdenv, nodejs, makeWrapper) routes through this repo's pinned nixpkgs
# instead of the consumer's. This gives cache-hit parity against CI's
# standalone build (see dev/fragments/overlays/overlay-pattern.md).
#
# Argument shape adapted from legacy curried pattern during Milestone 5 port.
{
  inputs,
  final,
  nv,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  inherit (ourPkgs) makeWrapper nodejs;
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
