{repoPath, ...}: {
  documentation.genericDescriptions.bruno = "Open-source IDE for exploring and testing APIs";
  update.targets.bruno = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/generic/bruno/package.nix)];};
}
