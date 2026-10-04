{
  facetOwner,
  repoPath,
  ...
}: {
  documentation = {
    aiCliDescriptions.kimchi = "Kimchi CLI";
    skillDescriptions = {
      kimchi-docs = "Search the pinned Kimchi docs snapshot; enable via ai.programs.kimchi-docs.enable";
      kimchi-workflow = "Launch a headless Kimchi workflow and read its durable result; enable via ai.programs.kimchi-workflow.enable";
    };
  };
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
  fragments.categories.kimchi-workflow = {
    scopes = [
      "packages/${facetOwner}/lib/mkWorkflow*.nix"
      "packages/${facetOwner}/skills/kimchi-workflow/**"
      "packages/${facetOwner}/src/workflow-run/**"
    ];
    sources = [
      {
        dir = facetOwner;
        location = "package";
        name = "kimchi-workflow";
      }
    ];
  };
  # The package update script refreshes the pinned Kimchi and pi extraction
  # sources, then regenerates extracted.json after every version bump.
  update.targets.kimchi = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/kimchi/package.nix)];};
  update.targets.kimchi-docs = {flags = ["--use-update-script"];};
}
