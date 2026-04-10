# github-mcp — builds the GitHub MCP server from the nvfetcher-tracked source
# via buildGoModule.
#
# Instantiates `ourPkgs` from `inputs.nixpkgs` so every build input
# (go toolchain + buildGoModule) routes through this repo's pinned nixpkgs
# instead of the consumer's. This gives cache-hit parity against CI's
# standalone build (see dev/fragments/overlays/overlay-pattern.md).
#
# Argument shape adapted from legacy curried pattern during Milestone 5 port.
{
  inputs,
  final,
  nv,
  ...
}: let
  ourPkgs = import inputs.nixpkgs {
    inherit (final.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  inherit (ourPkgs) buildGoModule;
in
  buildGoModule {
    pname = "github-mcp";
    inherit (nv) version src vendorHash;
    subPackages = ["cmd/github-mcp-server"];
    ldflags = ["-s" "-w" "-X main.version=${nv.version}"];
    meta.mainProgram = "github-mcp-server";
  }
