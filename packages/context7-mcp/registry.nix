{repoPath, ...}: {
  documentation.mcpServerMeta.context7-mcp = {
    description = "Library documentation lookup";
    credentials = "None";
  };
  update.targets.context7-mcp = {
    file = repoPath ./packages/ai/mcpServers/context7-mcp/package.nix;
    flags = ["--version" "skip"];
    git = "https://github.com/upstash/context7.git";
  };
}
