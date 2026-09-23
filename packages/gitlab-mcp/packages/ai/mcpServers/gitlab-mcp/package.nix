# gitlab-mcp — builds the GitLab MCP server via buildNpmPackage.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` so every build input
# (buildNpmPackage, nodejs, makeWrapper) routes through this repo's pinned
# nixpkgs instead of the consumer's. This gives cache-hit parity against
# CI's standalone build (see dev/fragments/overlays/overlay-pattern.md).
{
  pkgs,
  packageLib,
  ...
}: let
  ourPkgs = pkgs;
  inherit (ourPkgs) buildNpmPackage bun fetchgit makeWrapper;
  vu = packageLib;

  rev = "fbb6510288148b55d9e26388c7d86d46984b3d68";
  src = fetchgit {
    url = "https://github.com/zereight/gitlab-mcp.git";
    inherit rev;
    hash = "sha256-iYM305NNdey2KMFy1j1EnSrpVF+thaMVSIoluVseo6s=";
  };
in
  buildNpmPackage {
    pname = "gitlab-mcp";
    version = vu.mkVersion {
      # upstream: readPackageJsonVersion @ package.json
      upstream = "2.1.66";
      inherit rev;
    };
    inherit src;
    npmDepsHash = "sha256-QOh9L88stJFQhnkjoETJE4bbdo6D2mKBKsABWQ/X57Y=";
    nativeBuildInputs = [makeWrapper];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/gitlab-mcp $out/bin
      cp -r build node_modules package.json $out/lib/gitlab-mcp/
      makeWrapper ${bun}/bin/bun $out/bin/gitlab-mcp \
        --add-flags "$out/lib/gitlab-mcp/build/index.js"
      runHook postInstall
    '';
    doInstallCheck = true;
    installCheckPhase = vu.mkMcpSmokeTest {bin = "gitlab-mcp";};
    meta = {
      description = "GitLab platform integration MCP server";
      homepage = "https://github.com/zereight/gitlab-mcp";
      license = ourPkgs.lib.licenses.mit;
      mainProgram = "gitlab-mcp";
    };
  }
