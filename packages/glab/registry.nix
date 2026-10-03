{repoPath, ...}: {
  documentation.devToolDescriptions.glab = "GitLab CLI";
  update.targets.glab = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/devTools/glab/package.nix)];};
}
