{repoPath, ...}: {
  documentation.genericDescriptions.cli-proxy-api = "OpenAI-compatible proxy for AI CLI subscriptions and APIs";
  update.targets.cli-proxy-api = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/generic/cli-proxy-api/package.nix)];};
}
