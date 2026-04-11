# effect-mcp — builds the Effect MCP server from nvfetcher-tracked
# GitHub source via pnpm + tsup.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` so every build input
# routes through this repo's pinned nixpkgs for cache-hit parity
# (see dev/fragments/overlays/overlay-pattern.md).
{
  inputs,
  final,
  nv,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchPnpmDeps makeWrapper nodejs pnpm pnpmConfigHook;
in
  ourPkgs.stdenv.mkDerivation (finalAttrs: {
    pname = "effect-mcp";
    inherit (nv) version src;
    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      fetcherVersion = 3;
      hash = nv.pnpmDepsHash or "";
    };
    nativeBuildInputs = [makeWrapper nodejs pnpm pnpmConfigHook];
    buildPhase = ''
      runHook preBuild
      pnpm build
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/effect-mcp $out/bin
      cp -r dist/* $out/lib/effect-mcp/
      makeWrapper ${nodejs}/bin/node $out/bin/effect-mcp \
        --add-flags "$out/lib/effect-mcp/main.cjs"
      runHook postInstall
    '';
    meta.mainProgram = "effect-mcp";
  })
