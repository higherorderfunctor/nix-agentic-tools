{repoPath, ...}: {
  documentation.mcpServerMeta.kagi-mcp = {
    description = "Kagi search and summarization";
    credentials = "Required";
  };
  update.targets.kagi-mcp = {
    file = repoPath ./packages/ai/mcpServers/kagi-mcp/package.nix;
    flags = ["--version" "skip"];
    git = "https://github.com/kagisearch/kagimcp.git";
  };
}
