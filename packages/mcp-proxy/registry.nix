{repoPath, ...}: {
  documentation.mcpServerMeta.mcp-proxy = {
    description = "stdio-to-HTTP bridge proxy";
    credentials = "None";
  };
  update.targets.mcp-proxy = {
    file = repoPath ./packages/ai/mcpServers/mcp-proxy/package.nix;
    flags = ["--version" "skip"];
    git = "https://github.com/sparfenyuk/mcp-proxy.git";
  };
}
