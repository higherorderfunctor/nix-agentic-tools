{repoPath, ...}: {
  documentation.gitToolDescriptions.git-absorb = "Automatic fixup commit routing";
  update.targets.git-absorb = {
    file = repoPath ./packages/ai/gitTools/git-absorb/package.nix;
    flags = ["--version" "skip"];
    git = "https://github.com/tummychow/git-absorb.git";
    dependsOn = ["rust-overlay"];
  };
}
