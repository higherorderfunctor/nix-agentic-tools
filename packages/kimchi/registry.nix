{
  facetOwner,
  repoPath,
  ...
}: {
  checks.cacheHitParity.kimchi = {consumerPath = ["ai" "kimchi"];};
  documentation.aiCliDescriptions.kimchi = "Kimchi CLI";
  # kimchi: two-tree factory (config.json + harness/), runtime SOPS
  # credential, wrapProgram separator + flattenDotKeys gotchas.
  fragments.categories.kimchi = {
    scopes = [
      "packages/${facetOwner}/**"
    ];
    sources = [
      {
        location = "package";
        name = "kimchi-factory";
        dir = facetOwner;
      }
    ];
  };
  # The package update script refreshes the pinned Kimchi and pi extraction
  # sources, then regenerates extracted.json after every version bump.
  update.targets.kimchi = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/kimchi/package.nix)];};
}
