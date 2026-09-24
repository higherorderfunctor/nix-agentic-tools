{
  facetOwner,
  repoPath,
  ...
}: {
  checks.cacheHitParity.kimchi = {consumerPath = ["ai" "kimchi"];};
  checks.cacheHitParity.kimchi-docs = {consumerPath = ["docs" "kimchi-docs"];};
  documentation.aiCliDescriptions.kimchi = "Kimchi CLI";
  documentation.skillDescriptions.kimchi-docs = "Search the pinned Kimchi docs snapshot; enable via ai.programs.kimchi-docs.enable";
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
  update.targets.kimchi = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/kimchi/package.nix)];};
  update.targets.kimchi-docs = {flags = ["--use-update-script"];};
}
