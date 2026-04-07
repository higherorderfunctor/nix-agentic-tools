# Instantiate `ourPkgs` from `inputs.nixpkgs` so every build input
# (go toolchain + buildGoModule) routes through this repo's pinned
# nixpkgs instead of the consumer's. This is what gives the store
# path cache-hit parity against CI's standalone build — see
# dev/fragments/overlays/cache-hit-parity.md.
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
  nv = nv-sources.github-mcp-server;
in
  buildGoModule {
    pname = "github-mcp";
    inherit (nv) version src vendorHash;
    subPackages = ["cmd/github-mcp-server"];
    ldflags = ["-s" "-w" "-X main.version=${nv.version}"];
    meta.mainProgram = "github-mcp-server";
  }
