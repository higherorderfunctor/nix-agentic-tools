# gitlab-mcp — builds the GitLab MCP server via buildNpmPackage.
{
  pkgs,
  packageLib,
  ...
}: let
  inherit (pkgs) buildNpmPackage fetchgit makeWrapper;
  bun = pkgs.ai.generic.bun;
  vu = packageLib;

  rev = "603a694d6fbbc3123584274ee1a617a59b3f22f0";
  src = fetchgit {
    url = "https://github.com/zereight/gitlab-mcp.git";
    inherit rev;
    hash = "sha256-gQUqITSjXq6Zp7323KfJaqX1Wwz8QYi5aAbA1wnjdLw=";
  };
in
  buildNpmPackage {
    pname = "gitlab-mcp";
    version = vu.mkVersion {
      # upstream: readPackageJsonVersion @ package.json
      upstream = "2.3.31";
      inherit rev;
    };
    inherit src;
    npmDepsHash = "sha256-7Q7qiUKsr+bwYvmI8X7NVqaIL7lSw3J+OfDAG7Pdk2I=";
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
