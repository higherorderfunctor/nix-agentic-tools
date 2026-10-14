{repoPath, ...}: {
  documentation.genericDescriptions.cliproxyapi = "OpenAI-compatible proxy for AI CLI subscriptions and APIs";
  update.targets.cliproxyapi = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/generic/cliproxyapi/package.nix)];};
}
