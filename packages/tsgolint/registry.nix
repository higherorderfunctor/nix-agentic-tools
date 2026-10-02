{repoPath, ...}: {
  # fetchSubmodules src: the fetchgit-mode prefetch writes the submodule hash.
  checks.cacheHitParity.tsgolint = {consumerPath = ["ai" "devTools" "tsgolint"];};
  documentation.devToolDescriptions.tsgolint = "Type-aware linting backend for oxlint (typescript-go)";
  update.targets.tsgolint = {
    file = repoPath ./packages/ai/devTools/tsgolint/package.nix;
    flags = ["--version" "skip"];
    git = "https://github.com/oxc-project/tsgolint.git";
  };
}
