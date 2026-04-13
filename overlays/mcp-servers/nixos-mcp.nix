# nixos-mcp — wraps the upstream mcp-nixos package from inputs.mcp-nixos.
#
# The upstream flake pins its own nixpkgs, so its store path is determined
# by that flake's evaluation — not the consumer's nixpkgs. System is read
# from final.stdenv.hostPlatform.system for consistency with the rest of the
# aggregator (dev/fragments/overlays/overlay-pattern.md).
#
# Consumed from flake input (not built locally).
{
  inputs,
  final,
  ...
}: let
  upstream = inputs.mcp-nixos.packages.${final.stdenv.hostPlatform.system}.default;
  vu = import ../lib.nix;
in
  upstream.overrideAttrs {
    passthru = (upstream.passthru or {}) // {mcpName = "nixos-mcp";};
    doInstallCheck = true;
    installCheckPhase = vu.mkMcpSmokeTest {bin = "mcp-nixos";};
  }
