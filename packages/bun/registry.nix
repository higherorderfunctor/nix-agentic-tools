{repoPath, ...}: {
  documentation.genericDescriptions.bun = "JavaScript runtime, bundler, transpiler and package manager";
  update.targets.bun = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/generic/bun/package.nix)];};
}
