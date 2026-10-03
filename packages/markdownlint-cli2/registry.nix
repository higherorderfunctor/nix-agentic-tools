{repoPath, ...}: {
  documentation.devToolDescriptions.markdownlint-cli2 = "Configuration-based markdown linter (markdownlint)";
  update.targets.markdownlint-cli2 = {
    # Upstream ships no package-lock.json, so nixpkgs vendors one and the
    # build symlinks it in. `--generate-lockfile` regenerates OUR copy
    # beside the overlay on every bump; without it a version bump would
    # build new source against the old dependency set.
    file = repoPath ./packages/ai/devTools/markdownlint-cli2/package.nix;
    flags = ["--generate-lockfile"];
  };
}
