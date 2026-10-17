{repoPath, ...}: {
  documentation.genericDescriptions.mcp = "Model Context Protocol Python SDK";
  update.targets.mcp = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/generic/mcp/package.nix)];};
}
