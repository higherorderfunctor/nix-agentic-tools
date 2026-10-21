{
  facetOwner,
  repoPath,
  ...
}: {
  documentation = {
    aiCliDescriptions.kimchi = "Kimchi CLI with optional external source-built workflows (ai.kimchi.extensions.workflows)";
    skillDescriptions.kimchi-docs = "Search the pinned Kimchi docs snapshot and independently pinned workflows source, docs and examples; enable via ai.programs.kimchi-docs.enable";
  };
  fragments.categories = {
    # kimchi: two-tree factory (config.json + harness/), runtime SOPS
    # credential, wrapProgram separator + flattenDotKeys gotchas.
    kimchi = {
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
    # kimchi-codeql: the release's CodeQL database, its query runner and the
    # local query loop.
    kimchi-codeql = {
      scopes = [
        "packages/${facetOwner}/checks/kimchi-codeql.nix"
        "packages/${facetOwner}/lib/codeql.nix"
        "packages/${facetOwner}/ql/**"
      ];
      sources = [
        {
          location = "package";
          name = "kimchi-codeql";
          dir = facetOwner;
        }
      ];
    };
  };
  # The package update script refreshes the pinned Kimchi and pi extraction
  # sources, then regenerates packages/kimchi/extracted/ facts after every version bump.
  update.targets = {
    kimchi = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/kimchi/package.nix)];};
    kimchi-docs = {flags = ["--use-update-script"];};
    kimchi-workflows = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/kimchiExtensions/kimchi-workflows/package.nix)];};
  };
}
