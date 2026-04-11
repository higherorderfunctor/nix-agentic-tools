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
  inherit (ourPkgs) buildNpmPackage fetchgit makeWrapper nodejs;
in
  buildNpmPackage {
    pname = "git-intel-mcp";
    version = "unstable-2026-03-18";
    src = fetchgit {
      url = "https://github.com/hoangsonww/GitIntel-MCP-Server.git";
      rev = "9f216bab8d6bc3a3b850ad77f27d02d63a71e10d";
      hash = "sha256-UCIUmU6slN9EjL8Bf2JKfvyoVKE0jgUsfLd8OocdwNc=";
    };
    npmDepsHash = "sha256-v3b05ZPeUzmweTen/bzsBDUsuNur8+KbKmYXw2vh8do=";
    postPatch = "cp ${../sources/locks/git-intel-mcp-package-lock.json} package-lock.json";
    nativeBuildInputs = [makeWrapper];
    installPhase = ''
      runHook preInstall
      mkdir -p $out/lib/git-intel-mcp $out/bin
      cp -r dist node_modules package.json $out/lib/git-intel-mcp/
      makeWrapper ${nodejs}/bin/node $out/bin/git-intel-mcp \
        --add-flags "$out/lib/git-intel-mcp/dist/index.js"
      runHook postInstall
    '';
    meta.mainProgram = "git-intel-mcp";
  }
