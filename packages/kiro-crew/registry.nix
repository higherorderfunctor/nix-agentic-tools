{repoPath, ...}: {
  checks.cacheHitParity.kiro-crew = {consumerPath = ["ai" "kiro-crew"];};
  documentation.aiCliDescriptions.kiro-crew = "Kiro Crew";
  update.targets.kiro-crew = {
    file = repoPath ./packages/ai/kiro-crew/package.nix;
    flags = ["--version" "skip"];
    git = "https://github.com/kirodotdev/KiroCrew.git";
  };
}
