{repoPath, ...}: {
  documentation.aiCliDescriptions.anthropic-cli = "Official CLI for the Claude Platform";
  update.targets.anthropic-cli = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/anthropic-cli/package.nix)];};
}
