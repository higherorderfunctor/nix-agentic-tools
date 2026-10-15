# Workspace documents are excluded; the CI-only Hestia package has a target.
{repoPath, ...}: {
  update.excludePatterns = ["^docs" "^instructions-" "^repo-"];
  update.targets.ci-hestia = {
    file = repoPath ../dev/ci-hestia.nix;
    flags = ["--override-filename" (repoPath ../dev/ci-hestia.nix)];
  };
}
