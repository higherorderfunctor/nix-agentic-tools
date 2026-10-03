{repoPath, ...}: {
  documentation.mcpServerMeta.github-mcp = {
    description = "GitHub platform integration";
    credentials = "Required";
  };
  update.targets.github-mcp = {
    file = repoPath ./packages/ai/mcpServers/github-mcp/package.nix;
    flags = ["--version" "skip"];
    git = "https://github.com/github/github-mcp-server.git";
  };
}
