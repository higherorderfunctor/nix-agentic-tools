{repoPath, ...}: {
  documentation.genericDescriptions.cpa-manager-plus = "CPA Manager Plus dashboard and management server";
  update.targets.cpa-manager-plus = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/generic/cpa-manager-plus/package.nix)];};
}
