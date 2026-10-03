{repoPath, ...}: {
  documentation.genericDescriptions.oh-my-posh = "Prompt theme engine for any shell";
  update.targets.oh-my-posh = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/generic/oh-my-posh/package.nix)];};
}
