{repoPath, ...}: {
  update.targets.filesystem-mcp = {
    file = repoPath ./packages/ai/mcpServers/modelContextProtocol/all-mcps/package.nix;
    flags = ["--version" "skip"];
    git = "https://github.com/modelcontextprotocol/servers.git";
  };
}
