{repoPath, ...}: {
  checks.cacheHitParity = {
    kiro-crew = {consumerPath = ["ai" "kiro-crew"];};
    kiro-crew-embed-model = {consumerPath = ["ai" "kiro-crew-embed-model"];};
    kiro-crew-pptx-engine = {consumerPath = ["ai" "kiro-crew-pptx-engine"];};
  };
  documentation.aiCliDescriptions.kiro-crew = "Kiro Crew";
  update.targets.kiro-crew = {
    file = repoPath ./packages/ai/kiro-crew/package.nix;
    flags = ["--version" "skip"];
    git = "https://github.com/kirodotdev/KiroCrew.git";
  };
}
