# gitlab-mcp — builds the GitLab MCP server via buildNpmPackage.
{
  pkgs,
  packageLib,
  ...
}: let
  inherit (pkgs) buildNpmPackage fetchgit makeWrapper;
  bun = pkgs.ai.generic.bun;
  vu = packageLib;

  rev = "3db1dc9e0dddc623e0149539500450ae057ff966";
  src = fetchgit {
    url = "https://github.com/zereight/gitlab-mcp.git";
    inherit rev;
    hash = "sha256-R2JRC4VPcggnyd8scHE+34YmiCpWtE6maI9Jtbr54Uo=";
  };
in
  buildNpmPackage {
    pname = "gitlab-mcp";
    version = vu.mkVersion {
      # upstream: readPackageJsonVersion @ package.json
      upstream = "2.3.22";
      inherit rev;
    };
    inherit src;
    npmDepsHash = "sha256-hAvEhZmcxqTw1GqGNjarr3qLDhp2c55r204VW5bVJJ8=";
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
