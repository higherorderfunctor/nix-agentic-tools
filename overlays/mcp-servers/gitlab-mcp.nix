# gitlab-mcp — builds the GitLab MCP server via buildNpmPackage.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` so every build input
# (buildNpmPackage, nodejs, makeWrapper) routes through this repo's pinned
# nixpkgs instead of the consumer's. This gives cache-hit parity against
# CI's standalone build (see dev/fragments/overlays/overlay-pattern.md).
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) buildNpmPackage bun fetchgit makeWrapper;
  vu = import ../lib.nix;

  rev = "1e96fe627fdb133831ee363e5221abaa96290f26";
  src = fetchgit {
    url = "https://github.com/zereight/gitlab-mcp.git";
    inherit rev;
    hash = "sha256-dmclwBko0K7tYSVXas1D8tf1lTqyVXDBvk5fjxrDYis=";
  };
in
  buildNpmPackage {
    pname = "gitlab-mcp";
    version = vu.mkVersion {
      # upstream: readPackageJsonVersion @ package.json
      upstream = "2.1.16";
      inherit rev;
    };
    inherit src;
    npmDepsHash = "sha256-7TCOXr/JKVF1jAoSYykm5p4768GWR0GEK7v9KfkexMc=";
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
