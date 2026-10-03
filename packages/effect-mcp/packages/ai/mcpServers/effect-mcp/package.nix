# effect-mcp — builds the Effect MCP server from GitHub source via
# pnpm + tsup with inline hashes.
{
  pkgs,
  packageLib,
  ...
}: let
  inherit (pkgs) fetchPnpmDeps makeWrapper nodejs pnpmConfigHook;
  bun = pkgs.ai.generic.bun;
  # New nixpkgs makes the default `pnpm` be pnpm_11, which dropped
  # fetchPnpmDeps `fetcherVersion = 3`. Pin pnpm_10 for BOTH the deps
  # fetch and the build so they stay in lockstep
  # (see checks/packaging/pnpm-fetcher-parity.nix). Mirrors the context7-mcp owner recipe.
  pnpm = pkgs.ai.generic.pnpm_10;
  vu = packageLib;

  rev = "83a768303839b9e125f6c286369a5d9cc26c666e";
  src = pkgs.fetchFromGitHub {
    owner = "tim-smart";
    repo = "effect-mcp";
    inherit rev;
    hash = "sha256-okTpUZnYUfIuZThnqDKJ+FGImIeRLY2DMiS6HEQBoTQ=";
  };
in
  pkgs.stdenv.mkDerivation (finalAttrs: {
    pname = "effect-mcp";
    version = vu.mkVersion {
      # upstream: readPackageJsonVersion @ package.json
      upstream = "0.1.17";
      inherit rev;
    };
    inherit src;
    pnpmDeps = fetchPnpmDeps {
      inherit (finalAttrs) pname version src;
      inherit pnpm;
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
      makeWrapper ${bun}/bin/bun $out/bin/effect-mcp \
        --add-flags "$out/lib/effect-mcp/main.cjs"
      runHook postInstall
    '';
    doInstallCheck = true;
    installCheckPhase = vu.mkMcpSmokeTest {bin = "effect-mcp";};
    meta.mainProgram = "effect-mcp";
  })
