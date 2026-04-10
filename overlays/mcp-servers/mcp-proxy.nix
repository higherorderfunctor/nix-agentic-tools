# mcp-proxy — override nixpkgs to pin nvfetcher-tracked version.
#
# nixpkgs uses python3Packages.buildPythonApplication with finalAttrs
# and GitHub source. Our nvfetcher currently fetches from PyPI (flagged
# for migration to GitHub — see /tmp/nvfetcher-changes-needed.txt).
# The PyPI sdist works fine as src for the override.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` for cache-hit parity
# (see dev/fragments/overlays/overlay-pattern.md).
{
  inputs,
  final,
  nv,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
  };
  # httpx-auth has test failures in nixpkgs (jwt InsecureKeyLengthWarning)
  httpx-auth = ourPkgs.python3Packages.httpx-auth.overridePythonAttrs {doCheck = false;};
in
  ourPkgs.mcp-proxy.overridePythonAttrs (old: {
    inherit (nv) version src;
    # v0.11.0 added httpx-auth dependency (not in nixpkgs' v0.10.0)
    dependencies =
      (old.dependencies or [])
      ++ [httpx-auth];
    # Disable tests — PyPI sdist may lack test fixtures from GitHub repo.
    doCheck = false;
  })
