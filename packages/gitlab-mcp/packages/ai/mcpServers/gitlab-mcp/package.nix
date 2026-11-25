# gitlab-mcp — builds the GitLab MCP server via buildNpmPackage.
{
  pkgs,
  packageLib,
  ...
}: let
  inherit (pkgs) buildNpmPackage fetchgit makeWrapper;
  bun = pkgs.ai.generic.bun;
  vu = packageLib;

  rev = "9c0db5ea8e461dc11282d869e2101072164ec0ba";
  src = fetchgit {
    url = "https://github.com/zereight/gitlab-mcp.git";
    inherit rev;
    hash = "sha256-g9kuSG1SJ+HnjfuqkX96xjG9/slPXafAfI7isOAbUt0=";
  };
in
  buildNpmPackage {
    pname = "gitlab-mcp";
    version = vu.mkVersion {
      # upstream: readPackageJsonVersion @ package.json
      upstream = "3.0.0";
      inherit rev;
    };
    inherit src;
    npmDepsHash = "sha256-12I064ew50FG7VFMwS6nzIKcj2D9ORcptUsiqVMYHcQ=";
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
