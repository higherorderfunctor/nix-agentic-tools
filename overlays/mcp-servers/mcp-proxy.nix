# mcp-proxy — override nixpkgs to pin a newer version from GitHub.
#
# nixpkgs uses python3Packages.buildPythonApplication with finalAttrs
# and GitHub source. We override src/version to track upstream.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` for cache-hit parity
# (see dev/fragments/overlays/overlay-pattern.md).
{
  inputs,
  final,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  inherit (ourPkgs) fetchFromGitHub;
  # httpx-auth has test failures in nixpkgs (jwt InsecureKeyLengthWarning)
  httpx-auth = ourPkgs.python3Packages.httpx-auth.overridePythonAttrs {doCheck = false;};
in
  ourPkgs.mcp-proxy.overridePythonAttrs (old: {
    version = "unstable-2026-03-14";
    src = fetchFromGitHub {
      owner = "sparfenyuk";
      repo = "mcp-proxy";
      rev = "a6720cc4f0bb3a09748d61207fb33f3c7c8a88e4";
      hash = "sha256-Sx0YrCwTCV8wGmwzJPiEhOkHy4CcaKW4mtnLntE7qYU=";
    };
    # v0.11.0 added httpx-auth dependency (not in nixpkgs' v0.10.0)
    dependencies =
      (old.dependencies or [])
      ++ [httpx-auth];
    # Disable tests — PyPI sdist may lack test fixtures from GitHub repo.
    doCheck = false;
  })
