# The upstream `serena` flake pins its own nixpkgs, so its store
# path is determined by that flake's evaluation — not the consumer's
# nixpkgs. We still route `stdenv.hostPlatform.system` through the
# destructured arg (not `final`) to stay uniform with the rest of
# the overlay and avoid any principled reliance on the consumer's
# stdenv. See dev/fragments/overlays/overlay-pattern.md.
{inputs}: {stdenv, ...}: let
  upstream = inputs.serena.packages.${stdenv.hostPlatform.system}.default;
in
  upstream.overrideAttrs {
    passthru =
      (upstream.passthru or {})
      // {
        mcpArgs = ["start-mcp-server"];
        mcpName = "serena-mcp";
      };
  }
