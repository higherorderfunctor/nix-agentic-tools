# serena-mcp — wraps the upstream serena package from inputs.serena.
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
  upstream = inputs.serena.packages.${final.stdenv.hostPlatform.system}.default;
  vu = import ../lib.nix;
in
  upstream.overrideAttrs {
    passthru =
      (upstream.passthru or {})
      // {
        mcpArgs = ["start-mcp-server"];
        mcpName = "serena-mcp";
      };
    doInstallCheck = true;
    installCheckPhase = vu.mkMcpSmokeTest {
      bin = "serena";
      args = ["start-mcp-server"];
    };
  }
