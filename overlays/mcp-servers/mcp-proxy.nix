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
  vu = import ../lib.nix;
  # httpx-auth has test failures in nixpkgs (jwt InsecureKeyLengthWarning)
  httpx-auth = ourPkgs.python3Packages.httpx-auth.overridePythonAttrs {doCheck = false;};

  rev = "a6720cc4f0bb3a09748d61207fb33f3c7c8a88e4";
  src = fetchFromGitHub {
    owner = "sparfenyuk";
    repo = "mcp-proxy";
    inherit rev;
    hash = "sha256-Sx0YrCwTCV8wGmwzJPiEhOkHy4CcaKW4mtnLntE7qYU=";
  };
in
  ourPkgs.mcp-proxy.overridePythonAttrs (old: {
    version = vu.mkVersion {
      # upstream: readPyprojectVersion @ pyproject.toml
      upstream = "0.10.0";
      inherit rev;
    };
    inherit src;
    # v0.11.0 added httpx-auth dependency (not in nixpkgs' v0.10.0)
    dependencies =
      (old.dependencies or [])
      ++ [httpx-auth];
    nativeCheckInputs = with ourPkgs.python3Packages; [pytest pytest-asyncio];
    doInstallCheck = true;
    installCheckPhase = vu.mkMcpSmokeTest {bin = "mcp-proxy";};
  })
