{repoPath, ...}: {
  documentation.mcpServerMeta.slack-mcp = {
    description = "Slack search, messages, canvases and lists (remote)";
    credentials = "Required";
  };
  update.targets.slack-mcp = {
    flags = ["--use-update-script" "--override-filename" (repoPath ./packages/docs/slack-mcp/package.nix)];
  };
}
