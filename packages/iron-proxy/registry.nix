{repoPath, ...}: {
  documentation.genericDescriptions.iron-proxy = "Egress proxy for sandboxed agents: allowlisted hosts and secret injection";
  update.targets.iron-proxy = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/generic/iron-proxy/package.nix)];};
}
