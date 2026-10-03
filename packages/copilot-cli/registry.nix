{repoPath, ...}: {
  documentation.aiCliDescriptions.copilot-cli = "GitHub Copilot CLI";
  update.targets.copilot-cli = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/copilot-cli/package.nix)];};
}
