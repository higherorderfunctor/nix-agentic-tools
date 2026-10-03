{repoPath, ...}: {
  documentation.gitToolDescriptions.git-revise = "In-memory commit rewriting";
  update.targets.git-revise = {
    file = repoPath ./packages/ai/gitTools/git-revise/package.nix;
    flags = ["--version" "skip"];
    git = "https://github.com/mystor/git-revise.git";
  };
}
