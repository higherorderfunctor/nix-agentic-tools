{
  facetOwner,
  repoPath,
  ...
}: {
  documentation.aiCliDescriptions.kimchi = "Kimchi CLI with optional external source-built workflows (ai.kimchi.extensions.workflows.enable)";
  documentation.skillDescriptions.kimchi-docs = "Search the pinned Kimchi docs snapshot and independently pinned workflows source, docs and examples; enable via ai.programs.kimchi-docs.enable";
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
      {
        location = "package";
        name = "kimchi-workflows";
        dir = facetOwner;
      }
    ];
  };
  # The package update script refreshes the pinned Kimchi and pi extraction
  # sources, then regenerates extracted.json after every version bump.
  update.targets = {
    kimchi = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/kimchi/package.nix)];};
    kimchi-docs = {flags = ["--use-update-script"];};
    kimchi-workflows = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/kimchi-workflows/package.nix)];};
  };
}
