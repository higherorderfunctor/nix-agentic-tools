# effect-mcp — builds the Effect MCP server from GitHub source via
# pnpm + tsup with inline hashes.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` so every build input
# routes through this repo's pinned nixpkgs for cache-hit parity
# (see dev/fragments/overlays/overlay-pattern.md).
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchPnpmDeps makeWrapper nodejs pnpm pnpmConfigHook;
  vu = import ../lib.nix;

  rev = "83a768303839b9e125f6c286369a5d9cc26c666e";
  src = ourPkgs.fetchFromGitHub {
    owner = "tim-smart";
    repo = "effect-mcp";
    inherit rev;
    hash = "sha256-okTpUZnYUfIuZThnqDKJ+FGImIeRLY2DMiS6HEQBoTQ=";
  };
in
  ourPkgs.stdenv.mkDerivation (finalAttrs: {
    pname = "effect-mcp";
    version = vu.mkVersion {
      upstream = vu.readPackageJsonVersion "${src}/package.json";
      inherit rev;
    };
    inherit src;
    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      fetcherVersion = 3;
      hash = "sha256-8VCbs1gEKWGUD7nKxDL48RErzY0KW5k4fcW+chnAJ70=";
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
