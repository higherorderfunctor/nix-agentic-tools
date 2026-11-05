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
    # local query loop, and the environment, network, regionRegistry,
    # requestGuards and resourceDefinitions facts the database produces.
    kimchi-codeql = {
      scopes = [
        "packages/${facetOwner}/checks/fixtures/codeql-environment/**"
        "packages/${facetOwner}/checks/fixtures/network-expected.txt"
        "packages/${facetOwner}/checks/fixtures/network/**"
        "packages/${facetOwner}/checks/fixtures/request-evidence/**"
        "packages/${facetOwner}/checks/kimchi-codeql-network.nix"
        "packages/${facetOwner}/checks/kimchi-codeql-request-evidence.nix"
        "packages/${facetOwner}/checks/kimchi-codeql.nix"
        "packages/${facetOwner}/extract/environment.jq"
        "packages/${facetOwner}/extract/environment.nix"
        "packages/${facetOwner}/lib/codeql.nix"
        "packages/${facetOwner}/lib/network.jq"
        "packages/${facetOwner}/lib/network.nix"
        "packages/${facetOwner}/lib/request-evidence.nix"
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
          name = "kimchi-codeql-guards";
          dir = facetOwner;
        }
        {
          location = "package";
          name = "kimchi-codeql-network";
          dir = facetOwner;
        }
      ];
    };
    # kimchi-egress-report: field producers and the drift gate tying the
    # complete report to egressScan, environment, network, regionRegistry,
    # requestGuards and resourceDefinitions facts.
    kimchi-egress-report = {
      scopes = [
        "checks/references/kimchi-egress-report.nix"
        "packages/${facetOwner}/egress-report.json"
        "packages/${facetOwner}/extract/egress/**"
      ];
      sources = [
        {
          location = "package";
          name = "kimchi-egress-report";
          dir = facetOwner;
        }
      ];
    };
  };
  # The package update script refreshes the pinned Kimchi and pi extraction
  # sources; PR CI regenerates packages/kimchi/extracted/ facts, including
  # egressScan's scanner fields, and the complete egress report from those pins.
  update.targets = {
    kimchi = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/kimchi/package.nix)];};
    kimchi-docs = {flags = ["--use-update-script"];};
    kimchi-workflows = {flags = ["--use-update-script" "--override-filename" (repoPath ./packages/ai/kimchiExtensions/kimchi-workflows/package.nix)];};
  };
}
