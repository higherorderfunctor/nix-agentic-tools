{repoPath, ...}: {
  documentation.devToolDescriptions.rumdl = "Fast Rust markdown linter (markdownlint-compatible rules)";
  update.targets.rumdl = {
    flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/devTools/rumdl/package.nix)];
  };
}
