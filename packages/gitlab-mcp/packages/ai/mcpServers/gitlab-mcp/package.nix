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

  rev = "f2c13a55a5dc2bdda1efbd76c857c81fa4671fd1";
  src = fetchgit {
    url = "https://github.com/zereight/gitlab-mcp.git";
    inherit rev;
    hash = "sha256-ud8NE4mhE9ro7/UUC8gaGPfe7h3RWmuzwiir+ee/pJg=";
  };
in
  buildNpmPackage {
    pname = "gitlab-mcp";
    version = vu.mkVersion {
      # upstream: readPackageJsonVersion @ package.json
      upstream = "2.1.64";
      inherit rev;
    };
    inherit src;
    npmDepsHash = "sha256-reQcxjiOQkzgbFDZ0+tPUQ710JnbloiFcfDe+FQ5/+Y=";
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
