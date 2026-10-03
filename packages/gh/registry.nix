{repoPath, ...}: {
  documentation.devToolDescriptions.gh = "GitHub CLI";
  update.targets.gh = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/devTools/gh/package.nix)];};
}
