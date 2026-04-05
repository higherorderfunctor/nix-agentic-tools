final: let
  nv = final.nv-sources.mcp-language-server;
in
  final.buildGoModule {
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
