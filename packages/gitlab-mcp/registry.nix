{repoPath, ...}: {
  documentation.mcpServerMeta.gitlab-mcp = {
    description = "GitLab platform integration";
    credentials = "Required";
  };
  update.targets.gitlab-mcp = {
    file = repoPath ./packages/ai/mcpServers/gitlab-mcp/package.nix;
    flags = ["--version" "skip"];
    git = "https://github.com/zereight/gitlab-mcp.git";
  };
}
