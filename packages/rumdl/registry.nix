{repoPath, ...}: {
  documentation.devToolDescriptions.rumdl = "Fast Rust markdown linter (markdownlint-compatible rules)";
  update.targets.rumdl = {
    flags = ["--override-filename" (repoPath ./packages/ai/devTools/rumdl/package.nix)];
  };
}
