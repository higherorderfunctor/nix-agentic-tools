final: let
  nv = final.nv-sources.github-mcp-server;
in
  final.buildGoModule {
    pname = "github-mcp";
    inherit (nv) version src vendorHash;
    subPackages = ["cmd/github-mcp-server"];
    ldflags = ["-s" "-w" "-X main.version=${nv.version}"];
    meta.mainProgram = "github-mcp-server";
  }
