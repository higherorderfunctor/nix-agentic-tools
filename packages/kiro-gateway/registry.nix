{repoPath, ...}: {
  documentation.aiCliDescriptions.kiro-gateway = "Python proxy API for Kiro";
  update.targets.kiro-gateway = {
    file = repoPath ./packages/ai/kiro-gateway/package.nix;
    flags = ["--version" "skip"];
    git = "https://github.com/jwadow/kiro-gateway.git";
  };
}
