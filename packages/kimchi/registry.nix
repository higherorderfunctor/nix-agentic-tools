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
    # kimchi-codeql: the release's CodeQL database, its query runner, the
    # local query loop, and the environment and network facts the database
    # produces.
    kimchi-codeql = {
      scopes = [
        "packages/${facetOwner}/checks/fixtures/codeql-environment/**"
        "packages/${facetOwner}/checks/fixtures/network-expected.txt"
        "packages/${facetOwner}/checks/fixtures/network/**"
        "packages/${facetOwner}/checks/kimchi-codeql-network.nix"
        "packages/${facetOwner}/checks/kimchi-codeql.nix"
        "packages/${facetOwner}/extract/environment.jq"
        "packages/${facetOwner}/extract/environment.nix"
        "packages/${facetOwner}/lib/codeql.nix"
        "packages/${facetOwner}/lib/network.jq"
        "packages/${facetOwner}/lib/network.nix"
        "packages/${facetOwner}/ql/**"
      ];
      sources = [
        {
          location = "package";
          name = "kimchi-codeql";
          dir = facetOwner;
        }
        {
          location = "package";
          name = "kimchi-codeql-environment";
          dir = facetOwner;
        }
        {
          location = "package";
          name = "kimchi-codeql-network";
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
