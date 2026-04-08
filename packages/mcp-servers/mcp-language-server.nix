# Instantiate `ourPkgs` from `inputs.nixpkgs` so every build input
# (go toolchain + buildGoModule) routes through this repo's pinned
# nixpkgs instead of the consumer's. This is what gives the store
# path cache-hit parity against CI's standalone build — see
# dev/fragments/overlays/overlay-pattern.md.
{inputs}: {
  nv-sources,
  stdenv,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  inherit (ourPkgs) buildGoModule;
  nv = nv-sources.mcp-language-server;
in
  buildGoModule {
    pname = "mcp-language-server";
    inherit (nv) version src vendorHash;
    # main.go is at root; cmd/ only has a code generator tool
    subPackages = ["."];
    meta = {
      description = "MCP server wrapping any LSP server";
      homepage = "https://github.com/isaacphi/mcp-language-server";
      mainProgram = "mcp-language-server";
    };
  }
