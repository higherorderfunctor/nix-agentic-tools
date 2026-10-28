{repoPath, ...}: {
  documentation.genericDescriptions.fblog = "Command-line JSON log viewer";
  update.targets.fblog = {
    flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/generic/fblog/package.nix)];
  };
}
