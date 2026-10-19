{repoPath, ...}: {
  update.targets.slack-mcp = {
    flags = ["--use-update-script" "--override-filename" (repoPath ./packages/docs/slack-mcp/package.nix)];
  };
}
