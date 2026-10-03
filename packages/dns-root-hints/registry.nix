{repoPath, ...}: {
  documentation.genericDescriptions.dns-root-hints = "IANA DNS root name server hints (named.root)";
  update.targets.dns-root-hints = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/generic/dns-root-hints/package.nix)];};
}
