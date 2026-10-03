# nixos-mcp — builds the upstream mcp-nixos package via its exposed
# `lib.mkMcpNixos`, against the supplied package set.
#
# We deliberately do NOT consume `inputs.mcp-nixos.packages.<system>.default`.
# That evaluates the upstream flake's own `perSystem`, which applies its
# `fastmcp3` overlay pinning fastmcp to the pre-split PrefectHQ v3.2.4 flat
# repo. As of fastmcp 3.3.1, nixpkgs split the package into `fastmcp` +
# `fastmcp-slim` (the latter with `sourceRoot = "${src.name}/fastmcp_slim"`),
# and the 3.2.4 tarball has no `fastmcp_slim/` directory — so under a nixpkgs
# bump that overlay's unpackPhase fails (`cannot access source/fastmcp_slim`),
# which is what broke the nixpkgs bump in PR #328. nixpkgs now satisfies
# mcp-nixos's `fastmcp>=3.2.0` natively, so we build against stock
# `python3Packages.fastmcp` via the upstream-exposed `lib.mkMcpNixos`.
{
  inputs,
  pkgs,
  packageLib,
  ...
}: let
  upstream = inputs.mcp-nixos.lib.mkMcpNixos {inherit pkgs;};
  vu = packageLib;
in
  upstream.overrideAttrs {
    passthru = (upstream.passthru or {}) // {mcpName = "nixos-mcp";};
    doInstallCheck = true;
    installCheckPhase = vu.mkMcpSmokeTest {bin = "mcp-nixos";};
  }
