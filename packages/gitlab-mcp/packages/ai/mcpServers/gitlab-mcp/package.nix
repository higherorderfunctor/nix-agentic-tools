# gitlab-mcp — builds the GitLab MCP server via buildNpmPackage.
{
  pkgs,
  packageLib,
  ...
}: let
  inherit (pkgs) buildNpmPackage fetchgit makeWrapper;
  bun = pkgs.ai.generic.bun;
  vu = packageLib;

  rev = "282ecb27c207063592c16eb39d3c2819866430ea";
  src = fetchgit {
    url = "https://github.com/zereight/gitlab-mcp.git";
    inherit rev;
    hash = "sha256-mNbrD0zWfjDy0YSxJ4+XFbEz0Y0mq/4ScIzKBZvk7R8=";
  };
in
  buildNpmPackage {
    pname = "gitlab-mcp";
    version = vu.mkVersion {
      # upstream: readPackageJsonVersion @ package.json
      upstream = "2.1.70";
      inherit rev;
    };
    inherit src;
    npmDepsHash = "sha256-u/IoA0vGYw7IihYCbxtPvvRgmMC7/2MEfgOoY8YEtXM=";
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
