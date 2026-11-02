# gitlab-mcp — builds the GitLab MCP server via buildNpmPackage.
{
  pkgs,
  packageLib,
  ...
}: let
  inherit (pkgs) buildNpmPackage fetchgit makeWrapper;
  bun = pkgs.ai.generic.bun;
  vu = packageLib;

  rev = "b1df942e1f78d2d751eef90926c83f2dd00f6bbd";
  src = fetchgit {
    url = "https://github.com/zereight/gitlab-mcp.git";
    inherit rev;
    hash = "sha256-xz+yi49aPs1FzqQkFGe6LtoXJHSqYjPZT1DBnfi1kZA=";
  };
in
  buildNpmPackage {
    pname = "gitlab-mcp";
    version = vu.mkVersion {
      # upstream: readPackageJsonVersion @ package.json
      upstream = "2.3.19";
      inherit rev;
    };
    inherit src;
    npmDepsHash = "sha256-IJVGTD0v4cE+vxZf999fBEmePWAgf0PSTx5UENn4EKw=";
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
      license = pkgs.lib.licenses.mit;
      mainProgram = "gitlab-mcp";
    };
  }
