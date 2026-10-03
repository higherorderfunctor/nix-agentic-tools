{repoPath, ...}: {
  documentation.genericDescriptions = {
    pnpm_10 = "Fast, disk-space-efficient JavaScript package manager (10.x)";
    pnpm_11 = "Fast, disk-space-efficient JavaScript package manager (11.x)";
    pnpm_12 = "Fast, disk-space-efficient JavaScript package manager (12.x)";
  };
  update.targets = {
    pnpm_10 = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/generic/pnpm_10/package.nix)];};
    pnpm_11 = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/generic/pnpm_11/package.nix)];};
    pnpm_12 = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/generic/pnpm_12/package.nix)];};
  };
}
