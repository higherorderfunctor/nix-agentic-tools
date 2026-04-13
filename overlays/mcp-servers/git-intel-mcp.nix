# git-intel-mcp — builds the Git Intel MCP server via buildNpmPackage.
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
  inherit (ourPkgs) buildNpmPackage fetchgit git makeWrapper nodejs;
  vu = import ../lib.nix;

  rev = "9f216bab8d6bc3a3b850ad77f27d02d63a71e10d";
  src = fetchgit {
    url = "https://github.com/hoangsonww/GitIntel-MCP-Server.git";
    inherit rev;
    hash = "sha256-UCIUmU6slN9EjL8Bf2JKfvyoVKE0jgUsfLd8OocdwNc=";
  };
in
  buildNpmPackage {
    pname = "git-intel-mcp";
    version = vu.mkVersion {
      upstream = vu.readPackageJsonVersion "${src}/package.json";
      inherit rev;
    };
    inherit src;
    npmDepsHash = "sha256-/HN6Ylrow/v7ssWb0oIYJD5cTV8RWH8ipmDtfAUY9zc=";
    nativeBuildInputs = [makeWrapper];
    nativeCheckInputs = [git];
    doCheck = true;
    checkPhase = ''
      runHook preCheck
      HOME="$TMPDIR" node_modules/.bin/vitest run
      runHook postCheck
    '';
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/git-intel-mcp $out/bin
      cp -r dist node_modules package.json $out/lib/git-intel-mcp/
      makeWrapper ${nodejs}/bin/node $out/bin/git-intel-mcp \
        --add-flags "$out/lib/git-intel-mcp/dist/index.js"
      runHook postInstall
    '';
    doInstallCheck = true;
    installCheckPhase = vu.mkMcpSmokeTest {bin = "git-intel-mcp";};
    meta.mainProgram = "git-intel-mcp";
  }
